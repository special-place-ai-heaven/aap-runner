# windows/dotnet-*: .NET SDK build, run, framework-dependent publish (apphost) and pack (nupkg) with no package source,
# so every targeting, host and runtime pack must already be installed. global.json selects the SDK feature band.
# Sabotage missing-targeting-pack targets net7.0, whose targeting pack the profile does not install.
param(
    [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '',
    [Parameter(Mandatory)][string]$Tfm, [Parameter(Mandatory)][string]$SdkBand
)
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $env:DOTNET_CLI_HOME = Join-Path $Work 'dotnet-home'
    $env:NUGET_PACKAGES = Join-Path $Work 'nuget-packages'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:MSBUILDDISABLENODEREUSE = '1'
    if ($Sabotage -eq 'missing-targeting-pack') { $Tfm = 'net7.0'; Write-Line 'sabotage missing-targeting-pack applied (net7.0)' }
    $dotnet = Resolve-Exe 'dotnet.exe'
    if (-not $dotnet) { throw 'dotnet.exe not found on PATH' }
    Copy-Source (Join-Path $PSScriptRoot 'app') 'app'
    Set-Location -LiteralPath (Join-Path $Work 'app')
    $proj = Join-Path (Get-Location) 'ParityApp.csproj'
    Write-Utf8 $proj ((Get-Content -Raw -LiteralPath $proj).Replace('@TFM@', $Tfm))
    Write-Utf8 (Join-Path (Get-Location) 'global.json') ('{ "sdk": { "version": "' + $SdkBand + '", "rollForward": "latestFeature" } }')
    $sdk = (Invoke-Tool $dotnet @('--version')).Lines | Select-Object -Last 1
    $major = $SdkBand.Split('.')[0] + '.' + $SdkBand.Split('.')[1] + '.'
    Add-Fact 'dotnet.sdk_band' $sdk ('^' + [regex]::Escape($major)) -Match
    if (-not $Sabotage) { Add-Fact 'dotnet.sdk_in_baseline' ((Get-Oracle 'versions/dotnet_sdks') -contains $sdk) $true }

    $common = @('-c', 'Release', '-nodeReuse:false', '-p:UseSharedCompilation=false')
    Invoke-Tool $dotnet (@('build') + $common) | Out-Null
    $run = (Invoke-Tool $dotnet @('run', '-c', 'Release', '--no-build')).Lines -join ' '
    Invoke-Tool $dotnet (@('publish', '-o', 'pub') + $common) | Out-Null
    $pub = (Invoke-Tool 'pub\ParityApp.exe').Lines -join ' '
    Invoke-Tool $dotnet (@('pack', '-o', 'pkg', '--no-build') + $common) | Out-Null
    $want = 'hello from dotnet sum=10 x64=True windows=True'
    Add-Fact 'dotnet.run.output' $run $want
    Add-Fact 'publish.apphost.output' $pub $want
    $pe = Get-PeInfo 'pub\ParityApp.exe'
    Add-Fact 'publish.apphost.machine' $pe.Machine 'x64'
    # the core-properties part name is random per pack; keep its folder
    $entries = @(Get-ZipEntries 'pkg\Aap.Parity.App.1.0.0.nupkg' | ForEach-Object { $_ -replace '/[0-9a-f]{32}\.psmdcp$', '/<id>.psmdcp' })
    Add-Fact 'pack.contains_dll' ($entries -contains "lib/$Tfm/ParityApp.dll") $true
    Write-Report (@("tfm=$Tfm", "run.output=$run", "apphost.output=$pub", "apphost.machine=$($pe.Machine)") + ($entries | ForEach-Object { "nupkg.entry=$_" }))
}
