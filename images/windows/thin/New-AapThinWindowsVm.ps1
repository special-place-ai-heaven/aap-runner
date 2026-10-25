#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidatePattern('^(?=.{1,15}$)(?![0-9]+$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$')]
    [string]$VMName = 'aap-win-thin',
    [ValidateNotNullOrEmpty()][string]$LabRoot = 'E:/aap-runner/thin-vm',
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$IsoPath,
    [ValidateNotNullOrEmpty()][string]$Edition = 'Windows Server 2025 Standard (Desktop Experience)',
    [ValidateRange(32, 65536)][int]$VhdSizeGB = 250,
    [ValidateRange(1, 1024)][int]$CpuCount = 8,
    [ValidateRange(2, 1024)][int]$MemoryGB = 8,
    [ValidateRange(2, 1024)][int]$MinimumMemoryGB = 4,
    [ValidateRange(2, 1024)][int]$MaximumMemoryGB = 32,
    [ValidateRange(5, 2000)][int]$Buffer = 20,
    [ValidateNotNullOrEmpty()][string]$SwitchName = 'Default Switch'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($MinimumMemoryGB -gt $MemoryGB -or $MemoryGB -gt $MaximumMemoryGB) {
    throw 'Dynamic memory requires MinimumMemoryGB <= MemoryGB <= MaximumMemoryGB.'
}
$moduleRoot = $PSScriptRoot
Import-Module (Join-Path $moduleRoot '..\AapWinImage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $moduleRoot '..\AapWinImage.HyperV.psm1') -Force -ErrorAction Stop
$provider = New-AapWinHyperVProvider

if ($LabRoot -notmatch '^[A-Za-z]:[\\/]') { throw 'LabRoot must be an absolute local drive path.' }
$LabRoot = [IO.Path]::GetFullPath($LabRoot).TrimEnd('\')
if ($LabRoot -eq [IO.Path]::GetPathRoot($LabRoot).TrimEnd('\')) { throw 'LabRoot cannot be a drive root.' }
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
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $randomBytes = New-Object byte[] 32
    $random.GetBytes($randomBytes)
    $password = [Convert]::ToBase64String($randomBytes) + 'aA1!'
} finally { $random.Dispose() }
$passwordPath = Join-Path $LabRoot 'admin-password.txt'
[IO.File]::WriteAllText($passwordPath, $password, (New-Object Text.UTF8Encoding($false)))
Set-AdminOnlyAcl $passwordPath
$answer = New-AapWinUnattend -UserName 'aapadmin' -Password $password
$password = $null
$vhdPath = Join-Path $LabRoot ($VMName + '.vhdx')
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
try {
    $env:TEMP = $scratch
    $env:TMP = $scratch
    & $provider.NewBuildDisk @{ Path = $vhdPath; SizeGib = $VhdSizeGB; Format = $false }
    $image = & $provider.ApplyWindowsImage @{
        IsoPath = $IsoPath
        Edition = $Edition
        Vhdx = $vhdPath
        Files = @{ 'Windows\Panther\unattend.xml' = $answer }
        CopyFiles = @{}
    }
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    $answer = $null
}
Write-Host "Applied $Edition (image index $($image.ImageIndex))."

$vm = Hyper-V\New-VM -Name $VMName -Path $LabRoot -Generation 2 -MemoryStartupBytes ([int64]$MemoryGB * 1GB) -VHDPath $vhdPath -SwitchName $switch[0].Name
Hyper-V\Set-VMProcessor -VM $vm -Count $CpuCount
Hyper-V\Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -StartupBytes ([int64]$MemoryGB * 1GB) -MinimumBytes ([int64]$MinimumMemoryGB * 1GB) -MaximumBytes ([int64]$MaximumMemoryGB * 1GB) -Buffer $Buffer
Hyper-V\Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -AutomaticStartAction StartIfRunning -AutomaticStartDelay 30 -AutomaticStopAction ShutDown -SnapshotFileLocation $LabRoot -SmartPagingFilePath $LabRoot
Hyper-V\Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
$vmAccount = New-Object Security.Principal.NTAccount('NT VIRTUAL MACHINE', $vm.Id.ToString())
$acl = Get-Acl -LiteralPath $vhdPath
$rule = New-Object Security.AccessControl.FileSystemAccessRule($vmAccount, 'Modify', 'Allow')
[void]$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $vhdPath -AclObject $acl
$osDisk = @(Hyper-V\Get-VMHardDiskDrive -VM $vm)[0]
foreach ($dvd in @(Hyper-V\Get-VMDvdDrive -VM $vm)) { Hyper-V\Remove-VMDvdDrive -VMDvdDrive $dvd }
Hyper-V\Set-VMFirmware -VM $vm -FirstBootDevice $osDisk
Hyper-V\Start-VM -VM $vm
Write-Host "Started '$VMName' with $CpuCount vCPUs, dynamic RAM ($MemoryGB GiB startup, $MinimumMemoryGB-$MaximumMemoryGB GiB range, $Buffer% buffer) and a $VhdSizeGB GiB dynamic disk."
Write-Host 'Administrator credentials are in the protected admin-password.txt under LabRoot; no credential is printed.'
