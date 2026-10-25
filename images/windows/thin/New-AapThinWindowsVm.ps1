#Requires -RunAsAdministrator
<#
.SYNOPSIS
Creates one ordinary Windows Server evaluation VM; does not install a runner or change host networking.
.DESCRIPTION
Defaults to Generation 1 with BIOS/MBR setup; -Generation 2 selects UEFI setup with Secure Boot.
Run elevated on the Hyper-V host. LabRoot's parent must already exist. Refuses existing VMs and nonempty
LabRoot directories; a failed run leaves its own artifacts for inspection, never deletes an existing VM.
The answer ISO contains the setup credential: detach and delete it after setup, keeping admin-password.txt private.
The unmodified Microsoft installation DVD may require its initial "press any key to boot" console prompt.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^(?=.{1,15}$)(?![0-9]+$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')]
    [string]$VMName = 'aap-win-thin',
    [ValidateSet(1,2)][int]$Generation = 1,
    [ValidateNotNullOrEmpty()][string]$LabRoot = 'E:/aap-runner/thin-vm',
    [ValidateRange(32, 65536)][int]$VhdSizeGB = 250,
    [ValidateRange(2, 1024)][int]$MemoryGB = 8,
    [ValidateRange(2, 1024)][int]$MinimumMemoryGB = 4,
    [ValidateRange(2, 1024)][int]$MaximumMemoryGB = 32,
    [ValidateRange(5, 2000)][int]$Buffer = 20,
    [ValidateRange(1, 1024)][int]$CpuCount = 8,
    [ValidateNotNullOrEmpty()][string]$SwitchName = 'Default Switch',
    [string]$IsoPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($MinimumMemoryGB -gt $MemoryGB -or $MemoryGB -gt $MaximumMemoryGB) {
    throw 'Dynamic memory requires MinimumMemoryGB <= MemoryGB <= MaximumMemoryGB.'
}
Import-Module Hyper-V -ErrorAction Stop
Import-Module Storage -ErrorAction Stop
Import-Module Dism -ErrorAction Stop

if ($LabRoot -notmatch '^[A-Za-z]:[\\/]') { throw 'LabRoot must be an absolute local drive path.' }
$LabRoot = [IO.Path]::GetFullPath($LabRoot).TrimEnd('\')
if ($LabRoot -eq [IO.Path]::GetPathRoot($LabRoot).TrimEnd('\')) { throw 'LabRoot cannot be a drive root.' }
if ([string]::IsNullOrWhiteSpace($IsoPath)) {
    $isos = @(Get-ChildItem -LiteralPath 'C:/Users/poslj/Downloads' -Filter '*SERVER_EVAL_x64FRE_en-us.iso' -File -Recurse)
    if ($isos.Count -ne 1) { throw 'Expected exactly one *SERVER_EVAL_x64FRE_en-us.iso under C:/Users/poslj/Downloads; supply -IsoPath.' }
    $IsoPath = $isos[0].FullName
}
if ($IsoPath -notmatch '^[A-Za-z]:[\\/]' -or [IO.Path]::GetExtension($IsoPath) -ine '.iso') {
    throw 'IsoPath must be an absolute local .iso file path.'
}
$IsoPath = [IO.Path]::GetFullPath($IsoPath)
$protectedRoots = @('D:\', 'C:\wsl', 'C:\Program Files\aap-runner', 'C:\ProgramData\aap-runner', 'C:\aap-win-interim')
foreach ($path in @($LabRoot, $IsoPath)) {
    foreach ($root in $protectedRoots) {
        $prefix = $root.TrimEnd('\')
        if ($path -ieq $prefix -or $path.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'LabRoot and IsoPath must not use a protected live-install path or D:.'
        }
    }
}
if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw 'The installation ISO does not exist.' }
if (@(Hyper-V\Get-VM | Where-Object { $_.Name -ieq $VMName }).Count -ne 0) { throw "VM '$VMName' already exists; nothing was changed." }
$switch = @(Hyper-V\Get-VMSwitch | Where-Object { $_.Name -ieq $SwitchName })
if ($switch.Count -ne 1) { throw "Expected one existing switch named '$SwitchName'; no switch will be created." }
$ancestor = New-Object IO.DirectoryInfo $LabRoot
while ($null -ne $ancestor) {
    if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'LabRoot and its ancestors must not be reparse points.'
    }
    $ancestor = $ancestor.Parent
}
if (-not (Test-Path -LiteralPath (Split-Path -Parent $LabRoot) -PathType Container)) {
    throw 'Create LabRoot''s parent first; this script writes only inside LabRoot.'
}
if (Test-Path -LiteralPath $LabRoot) {
    if (-not (Test-Path -LiteralPath $LabRoot -PathType Container) -or @(Get-ChildItem -LiteralPath $LabRoot -Force).Count -ne 0) {
        throw 'LabRoot has prior artifacts; nothing was changed.'
    }
}
$templateName = if ($Generation -eq 1) { 'autounattend.bios.template.xml' } else { 'autounattend.template.xml' }
$templatePath = Join-Path $PSScriptRoot $templateName
$template = [IO.File]::ReadAllText($templatePath)
foreach ($placeholder in @('{{ADMIN_PASSWORD}}', '{{IMAGE_INDEX}}', '{{COMPUTER_NAME}}')) {
    if (-not $template.Contains($placeholder)) { throw 'The unattended setup template is missing a required placeholder.' }
}
$sourceImage = Get-DiskImage -ImagePath $IsoPath
if ($sourceImage.Attached) { throw 'The source ISO is already mounted; refusing to take ownership of its mount.' }

function Set-AdminOnlyAcl([string]$Path) {
    $isDirectory = Test-Path -LiteralPath $Path -PathType Container
    if ($isDirectory) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier $sid
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', $inheritance, 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if (-not (Test-Path -LiteralPath $LabRoot)) { [void](New-Item -ItemType Directory -Path $LabRoot) }
Set-AdminOnlyAcl $LabRoot
$scratch = Join-Path $LabRoot 'scratch'
[void](New-Item -ItemType Directory -Path $scratch)
$mounted = $false
try {
    $diskImage = Mount-DiskImage -ImagePath $IsoPath -Access ReadOnly -StorageType ISO -PassThru
    $mounted = $true
    $volumes = @($diskImage | Get-Volume | Where-Object { $_.DriveLetter })
    if ($volumes.Count -ne 1) { throw 'The source ISO must expose exactly one volume with a drive letter.' }
    $mediaRoot = "$($volumes[0].DriveLetter):\"
    $installPath = Join-Path $mediaRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $installPath -PathType Leaf)) { $installPath = Join-Path $mediaRoot 'sources\install.esd' }
    if (-not (Test-Path -LiteralPath $installPath -PathType Leaf)) { throw 'The source ISO has neither sources/install.wim nor sources/install.esd.' }
    $images = @(Get-WindowsImage -ImagePath $installPath -ScratchDirectory $scratch -LogPath (Join-Path $LabRoot 'media-inspection.log'))
    $selected = @()
    foreach ($edition in @('Standard', 'Datacenter')) {
        $selected = @($images | Where-Object { $_.ImageName -match "$edition.*\(Desktop Experience\)" })
        if ($selected.Count -gt 1) { throw "The source ISO has multiple $edition Desktop Experience images." }
        if ($selected.Count -eq 1) { break }
    }
    if ($selected.Count -ne 1) { throw 'The source ISO has no Standard or Datacenter Desktop Experience image.' }
    $imageIndex = [int]$selected[0].ImageIndex
} finally {
    if ($mounted) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
}
Write-Host "Selected $($selected[0].ImageName) (index $imageIndex)."

# Only IMAPI2FS builds the ISO. Native COM IStream interop avoids a plaintext XML file on the host.
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
try {
    $env:TEMP = $scratch
    $env:TMP = $scratch
    if (-not ('AapThinIsoStream' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
public static class AapThinIsoStream
{
    [DllImport("ole32.dll", PreserveSig = false)]
    private static extern void CreateStreamOnHGlobal(IntPtr memory, bool deleteOnRelease, out IStream stream);
    public static IStream FromXml(string xml)
    {
        IStream stream;
        CreateStreamOnHGlobal(IntPtr.Zero, true, out stream);
        try
        {
            byte[] bytes = new UTF8Encoding(false).GetBytes(xml);
            stream.Write(bytes, bytes.Length, IntPtr.Zero);
            stream.Seek(0, 0, IntPtr.Zero);
            return stream;
        }
        catch { Marshal.ReleaseComObject(stream); throw; }
    }
    public static void Save(object source, string path)
    {
        IStream stream = (IStream)source;
        IntPtr read = Marshal.AllocCoTaskMem(4);
        try
        {
            stream.Seek(0, 0, IntPtr.Zero);
            byte[] buffer = new byte[65536];
            using (FileStream file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                while (true)
                {
                    stream.Read(buffer, buffer.Length, read);
                    int count = Marshal.ReadInt32(read);
                    if (count == 0) break;
                    file.Write(buffer, 0, count);
                }
                file.Flush();
            }
        }
        finally { Marshal.FreeCoTaskMem(read); }
    }
}
'@
    }
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
}

$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $bytes = New-Object byte[] 32
    $random.GetBytes($bytes)
    $password = [Convert]::ToBase64String($bytes) + 'aA1!'
} finally { $random.Dispose() }
$passwordPath = Join-Path $LabRoot 'admin-password.txt'
[IO.File]::WriteAllText($passwordPath, $password, (New-Object Text.UTF8Encoding($false)))
Set-AdminOnlyAcl $passwordPath
$answerXml = $template.Replace('{{ADMIN_PASSWORD}}', [Security.SecurityElement]::Escape($password)).Replace('{{IMAGE_INDEX}}', [string]$imageIndex).Replace('{{COMPUTER_NAME}}', [Security.SecurityElement]::Escape($VMName))
$answerIso = Join-Path $LabRoot 'autounattend.iso'
$answerStream = $null
$fileSystem = $null
$result = $null
$isoStream = $null
try {
    $answerStream = [AapThinIsoStream]::FromXml($answerXml)
    $fileSystem = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fileSystem.FileSystemsToCreate = 3 # ISO9660 + Joliet, readable by Windows PE.
    $fileSystem.VolumeName = 'AAP_UNATTEND'
    $fileSystem.Root.AddFile('autounattend.xml', $answerStream)
    $result = $fileSystem.CreateResultImage()
    $isoStream = $result.ImageStream
    [AapThinIsoStream]::Save($isoStream, $answerIso)
} finally {
    foreach ($com in @($isoStream, $result, $fileSystem, $answerStream)) {
        if ($null -ne $com) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($com) }
    }
    $password = $null
    $answerXml = $null
    [Array]::Clear($bytes, 0, $bytes.Length)
}
Set-AdminOnlyAcl $answerIso

$vhdPath = Join-Path $LabRoot ($VMName + '.vhdx')
[void](Hyper-V\New-VHD -Path $vhdPath -SizeBytes ([int64]$VhdSizeGB * 1GB) -Dynamic)
$vm = Hyper-V\New-VM -Name $VMName -Path $LabRoot -Generation $Generation -MemoryStartupBytes ([int64]$MemoryGB * 1GB) -VHDPath $vhdPath -SwitchName $switch[0].Name
Hyper-V\Set-VMProcessor -VM $vm -Count $CpuCount
Hyper-V\Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -StartupBytes ([int64]$MemoryGB * 1GB) -MinimumBytes ([int64]$MinimumMemoryGB * 1GB) -MaximumBytes ([int64]$MaximumMemoryGB * 1GB) -Buffer $Buffer
Hyper-V\Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -AutomaticStartAction StartIfRunning -AutomaticStartDelay 30 -AutomaticStopAction ShutDown -SnapshotFileLocation $LabRoot -SmartPagingFilePath $LabRoot
# Grant only this VM disk read/write and setup-media read access; leave the password file admin-only.
$vmAccount = New-Object Security.Principal.NTAccount('NT VIRTUAL MACHINE', $vm.Id.ToString())
$vmRights = @{ $LabRoot = 'ReadAndExecute'; $answerIso = 'Read'; $vhdPath = 'Modify' }
foreach ($path in $vmRights.Keys) {
    $acl = Get-Acl -LiteralPath $path
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($vmAccount, $vmRights[$path], 'Allow')
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $path -AclObject $acl
}
if ($Generation -eq 1) {
    # Reuse the default IDE DVD so source media precedes the nonbootable answer disc.
    $windowsDvd = @(Hyper-V\Get-VMDvdDrive -VM $vm | Where-Object { $_.ControllerNumber -eq 1 -and $_.ControllerLocation -eq 0 })
    if ($windowsDvd.Count -eq 0) {
        [void](Hyper-V\Add-VMDvdDrive -VM $vm -ControllerNumber 1 -ControllerLocation 0 -Path $IsoPath)
    } else {
        Hyper-V\Set-VMDvdDrive -VMDvdDrive $windowsDvd[0] -Path $IsoPath
    }
    [void](Hyper-V\Add-VMDvdDrive -VM $vm -ControllerNumber 1 -ControllerLocation 1 -Path $answerIso)
    Hyper-V\Set-VMBios -VM $vm -StartupOrder @('CD','IDE')
} else {
    $windowsDvd = Hyper-V\Add-VMDvdDrive -VM $vm -Path $IsoPath -Passthru
    [void](Hyper-V\Add-VMDvdDrive -VM $vm -Path $answerIso)
    $osDisk = @(Hyper-V\Get-VMHardDiskDrive -VM $vm)[0]
    Hyper-V\Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -BootOrder @($windowsDvd, $osDisk)
}
Hyper-V\Start-VM -VM $vm
Write-Host "Started '$VMName' with $CpuCount vCPUs, dynamic RAM ($MemoryGB GiB startup, $MinimumMemoryGB-$MaximumMemoryGB GiB range, $Buffer% buffer) and a $VhdSizeGB GiB dynamic disk."
Write-Host 'Administrator credentials are in the protected admin-password.txt under LabRoot; no credential is printed.'
