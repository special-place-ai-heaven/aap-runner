# Non-elevated, read-only facts. Never start a distro or alter Windows/WSL configuration.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 3
$processors = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 3)
$wslVersion = ''
try {
    $package = Get-AppxPackage -Name MicrosoftCorporationII.WindowsSubsystemForLinux -ErrorAction Stop
    if ($package) { $wslVersion = [string]$package.Version }
} catch { }
if (-not $wslVersion -and (Test-Path 'C:\Program Files\WSL\wsl.exe')) {
    $wslVersion = [string](Get-Item 'C:\Program Files\WSL\wsl.exe').VersionInfo.ProductVersion
}
$operator = $false
foreach ($distro in @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue)) {
    $registration = Get-ItemProperty $distro.PSPath
    if ($registration.DistributionName -eq 'Ubuntu-24.04' -and $registration.Version -eq 2) { $operator = $true }
}
$policy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\WSL' -ErrorAction SilentlyContinue
$allowMount = $null -eq $policy -or $null -eq $policy.AllowDiskMount -or $policy.AllowDiskMount -ne 0
$config = ''
$profilePath = [Environment]::GetFolderPath('UserProfile')
$configPath = Join-Path $profilePath '.wslconfig'
if (Test-Path $configPath) {
    if ((Get-Item $configPath).Length -gt 4096) { throw 'wslconfig too large' }
    $config = [IO.File]::ReadAllText($configPath)
}
$network = $false
try {
    $request = [Net.HttpWebRequest]::Create('https://github.com')
    $request.Method = 'HEAD'; $request.Timeout = 3000; $request.ReadWriteTimeout = 3000
    $response = $request.GetResponse(); $network = [int]$response.StatusCode -lt 500; $response.Close()
} catch { }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = @($identity.Groups | ForEach-Object { $_.Value }) -contains 'S-1-5-32-544'
$uac = Get-Service Appinfo -ErrorAction SilentlyContinue
[ordered]@{
    build = [int]$os.CurrentBuildNumber
    virtualization = [bool]($computer.HypervisorPresent -or @($processors | Where-Object { $_.VirtualizationFirmwareEnabled }).Count -gt 0)
    wsl_version = $wslVersion
    operator_wsl2 = $operator
    allow_disk_mount = $allowMount
    free_gib = [long][Math]::Floor(([IO.DriveInfo]::new('C:\')).AvailableFreeSpace / 1GB)
    admin_available = [bool]($admin -and $uac -and $uac.StartType -ne 'Disabled')
    github = $network
    cpus = [int]$computer.NumberOfLogicalProcessors
    memory_gib = [int][Math]::Floor($computer.TotalPhysicalMemory / 1GB)
    wslconfig = $config
} | ConvertTo-Json -Compress
