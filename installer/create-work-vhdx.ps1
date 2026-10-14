# Create a fixed work VHDX. Bootstrap calls this once, from an elevated shell.
# SizeGiB is AAP_WORK_DISK_GIB (default 60; Fresh passes 100).
# A fixed VHDX cannot grow into C:.
# Prefer Hyper-V New-VHD -Fixed, then virtdisk CreateVirtualDisk. diskpart maximum= is MiB, so SizeGiB * 1024.
# PowerShell's 1GB is 1024^3, so New-VHD -SizeBytes (SizeGiB * 1GB) is the
# same size. New-VHD is absent, or it errors, on Windows Home and on any
# host whose Hyper-V Virtual Machine Management service (VMMS) is not
# running. That failure falls back to diskpart. The diskpart script is
# written in the VHDX directory after that directory is locked, then deleted.
# It is never written under %TEMP%.
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [int]$SizeGiB,
    # install-host.ps1 -TestMode. The VHDX stays writable by this user. No ACL lock.
    [switch]$SkipAcl
)
# powershell.exe 5.1 inherits pwsh 7's PSModulePath and then cannot autoload
# Microsoft.PowerShell.Security (Get-Acl CouldNotAutoload).
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
if ([string]::IsNullOrEmpty($env:PSModulePath)) {
    Write-Error 'refusing: machine PSModulePath is empty' -ErrorAction Continue
    exit 1
}
# Before the directory, the lock, the marker, or the VHDX.
if ($Path -notmatch '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.vhdx$') {
    Write-Error 'refusing: -Path must match ^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.vhdx$' -ErrorAction Continue
    exit 1
}
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$lock = Join-Path $PSScriptRoot 'lock-acl.ps1'
if (-not $SkipAcl) {
    & $lock -LiteralPath $dir
}
if (Test-Path -LiteralPath $Path) {
    if (-not $SkipAcl) {
        & $lock -LiteralPath $Path
    }
    Write-Output 'exists'
    exit 0
}
# Non-elevated fixed VHDX creation through virtdisk.dll CreateVirtualDisk.
# Creating the file needs no privilege; only attaching does.
function New-AapFixedVhdxNoAdmin([string]$Path, [int64]$Bytes) {
    if (-not ('AapVirtDisk' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AapVirtDisk {
    [StructLayout(LayoutKind.Sequential)]
    public struct VIRTUAL_STORAGE_TYPE { public uint DeviceId; public Guid VendorId; }
    [StructLayout(LayoutKind.Sequential)]
    public struct CREATE_VIRTUAL_DISK_PARAMETERS_V1 {
        public int Version; public Guid UniqueId; public ulong MaximumSize;
        public uint BlockSizeInBytes; public uint SectorSizeInBytes;
        public IntPtr ParentPath; public IntPtr SourcePath;
    }
    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
    public static extern uint CreateVirtualDisk(ref VIRTUAL_STORAGE_TYPE type, string path,
        uint mask, IntPtr sd, uint flags, uint providerFlags,
        ref CREATE_VIRTUAL_DISK_PARAMETERS_V1 p, IntPtr overlapped, out IntPtr handle);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static uint Create(string path, ulong bytes) {
        var t = new VIRTUAL_STORAGE_TYPE();
        t.DeviceId = 3; // VIRTUAL_STORAGE_TYPE_DEVICE_VHDX
        t.VendorId = new Guid("EC984AEC-A0F9-47e9-901F-71415A66345B");
        var p = new CREATE_VIRTUAL_DISK_PARAMETERS_V1();
        p.Version = 1; p.UniqueId = Guid.NewGuid(); p.MaximumSize = bytes;
        p.BlockSizeInBytes = 0; p.SectorSizeInBytes = 512;
        IntPtr h;
        // VIRTUAL_DISK_ACCESS_NONE (0) with V1 is rejected; use ALL (0x003f0000).
        // CREATE_VIRTUAL_DISK_FLAG_FULL_PHYSICAL_ALLOCATION = 1 (fixed).
        uint rc = CreateVirtualDisk(ref t, path, 0x003f0000, IntPtr.Zero, 1, 0, ref p, IntPtr.Zero, out h);
        if (rc == 0) { CloseHandle(h); }
        return rc;
    }
}
'@
    }
    return [AapVirtDisk]::Create($Path, [uint64]$Bytes)
}

$bytes = [int64]$SizeGiB * 1GB
$maximumMb = $SizeGiB * 1024
$created = ''
if (Get-Command New-VHD -ErrorAction SilentlyContinue) {
    try {
        New-VHD -Path $Path -SizeBytes $bytes -Fixed -ErrorAction Stop | Out-Null
        $created = 'New-VHD'
    } catch {
        Write-Warning "New-VHD failed; falling back to diskpart. $($_.Exception.Message)"
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    }
}
if (-not $created) {
    # virtdisk.dll CreateVirtualDisk: creating the file needs no elevation
    # (only attaching does), so -TestMode works from a non-admin shell.
    # Verified on Fresh (WSL 3.0.3): rc 0 as a standard user, lsblk shows
    # the exact byte size after wsl --mount --vhd --bare.
    try {
        $rc = New-AapFixedVhdxNoAdmin $Path $bytes
        if ($rc -eq 0) {
            $created = 'CreateVirtualDisk'
        } else {
            Write-Warning "CreateVirtualDisk failed (Win32 $rc); falling back to diskpart."
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        }
    } catch {
        Write-Warning "CreateVirtualDisk failed; falling back to diskpart. $($_.Exception.Message)"
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    }
}
if (-not $created) {
    # Same directory as the VHDX, already locked above. Not %TEMP%.
    $dp = Join-Path $dir 'aap-runner-diskpart.txt'
    $line = 'create vdisk file="{0}" maximum={1} type=fixed' -f $Path, $maximumMb
    Set-Content -Encoding ascii -Path $dp -Value $line
    try {
        $p = Start-Process -FilePath diskpart.exe -ArgumentList @('/s', $dp) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            Write-Error "diskpart create vdisk failed (exit $($p.ExitCode))" -ErrorAction Continue
            exit $p.ExitCode
        }
    } finally {
        if (Test-Path -LiteralPath $dp) {
            Remove-Item -LiteralPath $dp -Force -ErrorAction SilentlyContinue
        }
    }
    $created = 'diskpart'
}
if (-not $SkipAcl) {
    & $lock -LiteralPath $Path
}
Write-Output $created
