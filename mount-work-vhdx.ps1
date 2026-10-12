# Logon task for the installing operator. WSL mounts belong to that
# Windows user, so this script runs in the operator's elevated session.
# The only Windows path it operates on is the fixed VHDX.
# __AAP_VHDX__ is replaced at install. wsl output is appended under C:\wsl.
# powershell.exe 5.1 inherits pwsh 7's PSModulePath and then cannot autoload
# Microsoft.PowerShell.Security. The logon task sets this before the script.
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
if ([string]::IsNullOrEmpty($env:PSModulePath)) {
    Write-Error 'refusing: machine PSModulePath is empty' -ErrorAction Continue
    exit 1
}
$ErrorActionPreference = 'Stop'
$path = '__AAP_VHDX__'
$log = 'C:\wsl\mount-work-vhdx.log'
$stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'

function Write-MountLog([string]$Line) {
    try {
        Add-Content -LiteralPath $log -Encoding utf8 -Value $Line
    } catch {
        Write-Error -ErrorAction Continue "could not append ${log}: $($_.Exception.Message)"
    }
}

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-MountLog "${stamp} start user=${user} path=${path}"
# Windows PowerShell 5.1 under Stop turns any wsl.exe stderr line into a
# terminating error and exit 1, even when the mount succeeded. On Fresh the
# task attached the disk and still returned Last Result 1 while wsl.exe was
# printing "Unknown key 'wsl2.autoMemoryReclaim'" to stderr.
$ErrorActionPreference = 'Continue'
$output = & wsl.exe --mount --vhd $path --bare 2>&1 | ForEach-Object { "$_" } | Out-String
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($null -eq $code) {
    $code = 1
}
$text = ''
if ($output) {
    $text = $output.TrimEnd()
}
Write-MountLog "${stamp} exit=${code}"
if ($text) {
    Write-MountLog $text
}
if ($code -eq 0) {
    exit 0
}
if ($text -match 'already') {
    Write-MountLog "${stamp} already mounted; treating as success"
    exit 0
}
Write-Error -ErrorAction Continue $text
exit $code
