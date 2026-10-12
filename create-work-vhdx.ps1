# Create a fixed work VHDX. Bootstrap calls this once, from an elevated shell.
# SizeGiB is AAP_WORK_DISK_GIB (default 60; Fresh passes 100).
# A fixed VHDX cannot grow into C:.
# Prefer Hyper-V New-VHD -Fixed. diskpart maximum= is MiB, so SizeGiB * 1024.
# PowerShell's 1GB is 1024^3, so New-VHD -SizeBytes (SizeGiB * 1GB) is the
# same size. New-VHD is absent, or it errors, on Windows Home and on any
# host whose Hyper-V Virtual Machine Management service (VMMS) is not
# running. That failure falls back to diskpart, then the same ACL.
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [int]$SizeGiB
)
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$lock = Join-Path $PSScriptRoot 'lock-acl.ps1'
& $lock -LiteralPath $dir
if (Test-Path -LiteralPath $Path) {
    & $lock -LiteralPath $Path
    Write-Output 'exists'
    exit 0
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
    $dp = Join-Path $env:TEMP ("aap-runner-work-diskpart-{0}.txt" -f [guid]::NewGuid().ToString('n'))
    $line = 'create vdisk file="{0}" maximum={1} type=fixed' -f $Path, $maximumMb
    Set-Content -Encoding ascii -Path $dp -Value $line
    try {
        $p = Start-Process -FilePath diskpart.exe -ArgumentList @('/s', $dp) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            Write-Error "diskpart create vdisk failed (exit $($p.ExitCode))" -ErrorAction Continue
            exit $p.ExitCode
        }
    } finally {
        Remove-Item -LiteralPath $dp -Force -ErrorAction SilentlyContinue
    }
    $created = 'diskpart'
}
& $lock -LiteralPath $Path
Write-Output $created
