# windows/msbuild-netfx: Visual Studio's MSBuild (found with vswhere, not on PATH) builds a classic .NET Framework
# project against the installed targeting pack; no NuGet. Sabotage missing-targeting-pack asks for v4.0, which the
# profile does not install.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $vs = Get-VsInstall
    $r = Invoke-Tool $vs.VsWhere @('-latest', '-products', '*', '-requires', 'Microsoft.Component.MSBuild', '-find', 'MSBuild\**\Bin\MSBuild.exe') -Quiet
    $msbuild = $r.Lines | Select-Object -First 1
    if (-not $msbuild) { throw 'vswhere found no MSBuild.exe' }
    Add-Observation 'msbuild.path' $msbuild
    $tfv = Get-Oracle 'netfx_targeting_pack'
    if ($Sabotage -eq 'missing-targeting-pack') { $tfv = 'v4.0'; Write-Line 'sabotage missing-targeting-pack applied (v4.0)' }
    Copy-Source $PSScriptRoot 'proj'
    Set-Location -LiteralPath (Join-Path $Work 'proj')
    Invoke-Tool $msbuild @('Legacy.csproj', '/nologo', '/nr:false', '/v:m', '/p:Configuration=Release', "/p:TargetFrameworkVersion=$tfv") | Out-Null
    $exe = 'bin\Release\Legacy.exe'
    $out = (Invoke-Tool $exe).Lines -join ' '
    Add-Fact 'legacy.output' $out 'hello from netfx sum=10 clr=4'
    $pe = Get-PeInfo $exe
    Write-Report @("targeting_pack=$tfv", "output=$out", "machine=$($pe.Machine)", "subsystem=$($pe.Subsystem)")
}
