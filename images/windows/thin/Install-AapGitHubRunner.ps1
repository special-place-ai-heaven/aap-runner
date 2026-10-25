#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$RepoUrl,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$RegistrationToken,
    [ValidateNotNullOrEmpty()][string]$RunnerName = $env:COMPUTERNAME,
    [ValidateNotNullOrEmpty()][string]$InstallRoot = 'C:\aap-runner'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'aap-runner-thin-installer' }
$tempRoot = $null
$stage = 'preflight'
try {
    # Setup caches answer files containing the guest administrator password.
    # Delete only answer XML files, preserving setup logs and other artifacts.
    foreach ($cacheDirectory in @('Panther', 'System32\Sysprep')) {
        $cachePath = Join-Path $env:WINDIR $cacheDirectory
        if (Test-Path -LiteralPath $cachePath) {
            Get-ChildItem -LiteralPath $cachePath -Filter '*unattend*.xml' -File -Recurse -Force -ErrorAction Stop |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
        }
    }
    if ($RepoUrl -notmatch '^https://github\.com/[^/\s]+/[^/\s]+/?$') {
        throw 'Expected a GitHub repository HTTPS URL.'
    }
    if (Test-Path -LiteralPath (Join-Path $InstallRoot '.runner')) {
        throw 'A runner is already configured here.'
    }
    # Do not overwrite an incomplete installation or unrelated files.
    if ((Test-Path -LiteralPath $InstallRoot) -and @(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -ne 0) {
        throw 'InstallRoot must be empty.'
    }
    $tempRoot = Join-Path $env:TEMP ('aap-runner-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $stage = 'Git installation'
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers $headers
    $assets = @($release.assets | Where-Object { $_.name -match '^Git-[0-9].*-64-bit\.exe$' })
    if ($assets.Count -ne 1) { throw 'Expected one Git x64 installer.' }
    $installer = Join-Path $tempRoot 'git-installer.exe'
    Invoke-WebRequest -UseBasicParsing -Uri $assets[0].browser_download_url -Headers $headers -OutFile $installer
    $process = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT', '/NORESTART', '/SP-', '/SUPPRESSMSGBOXES' -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw 'Git installer failed.' }
    $git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
    $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $gitVersion = & $git --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Git is unavailable.' }
    Write-Output ('GIT|{0}' -f ($gitVersion -join ' '))

    $stage = 'runner download'
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Headers $headers
    $assets = @($release.assets | Where-Object { $_.name -match '^actions-runner-win-x64-[0-9][0-9.]*\.zip$' })
    if ($assets.Count -ne 1) { throw 'Expected one Windows x64 runner archive.' }
    $archive = Join-Path $tempRoot 'runner.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $assets[0].browser_download_url -Headers $headers -OutFile $archive
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $InstallRoot

    $stage = 'runner configuration'
    Push-Location -LiteralPath $InstallRoot
    try {
        # Suppress native output: failures must not echo the registration token.
        & .\config.cmd --url $RepoUrl --token $RegistrationToken --name $RunnerName --labels self-hosted,windows,x64 --unattended --runasservice *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Runner configuration failed.' }
    } finally {
        $RegistrationToken = $null
        Pop-Location
    }
    $stage = 'runner service'
    $service = Get-Service -Name 'actions.runner.*' | Select-Object -First 1
    if ($null -eq $service) { throw 'Runner service is missing.' }
    if ($service.Status -ne 'Running') { Start-Service -InputObject $service }
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    $service.Refresh()
    if ($service.Status -ne 'Running') { throw 'Runner service is not running.' }
    Write-Output 'RUNNER|Running'
} catch {
    # Never render exception details or invocation arguments containing secrets.
    Write-Output ('RUNNER|ERROR|{0}' -f $stage)
    exit 1
} finally {
    $RegistrationToken = $null
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
