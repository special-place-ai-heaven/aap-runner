# Create a fixed work VHDX. Bootstrap calls this once, from an elevated shell.
# A fixed VHDX cannot grow into C:.
# Prefer Hyper-V New-VHD -Fixed. If that cmdlet is absent, diskpart creates
# the same disk. diskpart maximum= is MiB, so SizeGiB * 1024. PowerShell's
# 1GB is 1024^3, so New-VHD -SizeBytes (SizeGiB * 1GB) is the same size.
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
if (Get-Command New-VHD -ErrorAction SilentlyContinue) {
    New-VHD -Path $Path -SizeBytes $bytes -Fixed | Out-Null
    & $lock -LiteralPath $Path
    Write-Output 'New-VHD'
    exit 0
}
$dp = Join-Path $env:TEMP 'aap-runner-work-diskpart.txt'
$line = 'create vdisk file="{0}" maximum={1} type=fixed' -f $Path, $maximumMb
Set-Content -Encoding ascii -Path $dp -Value $line
$p = Start-Process -FilePath diskpart.exe -ArgumentList @('/s', $dp) -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    exit $p.ExitCode
}
& $lock -LiteralPath $Path
Write-Output 'diskpart'
