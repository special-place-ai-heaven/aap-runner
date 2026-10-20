# windows/node-addon: a Node-API native addon built with MSVC (cl /LD against an import library made from node.def)
# and loaded by the job's node.exe. node-gyp is not used: it downloads Node headers, and workloads stay offline.
# Sabotage no-sdk-lib strips the SDK libraries from the developer environment.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $node = Resolve-Exe 'node.exe'
    if (-not $node) { throw 'node.exe not found on PATH' }
    if (-not $Sabotage) { Add-Fact 'node.dir' (Split-Path -Parent $node) (Get-Oracle 'bare_path/node_dir') }
    Enter-DevEnv -Arch x64 | Out-Null
    Set-DevEnvSabotage $Sabotage
    Copy-Source $PSScriptRoot 'addon'
    Set-Location -LiteralPath (Join-Path $Work 'addon')
    Invoke-Tool lib.exe @('/nologo', '/def:node.def', '/out:node.lib', '/machine:x64') | Out-Null
    Invoke-Tool cl.exe @('/nologo', '/W4', '/WX', '/LD', '/MD', '/O2', 'addon.c', 'node.lib', '/Feaddon.node') | Out-Null
    $out = (Invoke-Tool $node @('test.js')).Lines -join ' '
    Add-Fact 'addon.output' $out 'hello from a node-api addon'
    $pe = Get-PeInfo 'addon.node'
    Add-Fact 'addon.machine' $pe.Machine 'x64'
    Add-Fact 'addon.is_dll' $pe.Dll $true
    Add-Fact 'addon.imports.node' ((Get-PeImports 'addon.node') -contains 'node.exe') $true
    Write-Report @("output=$out", "machine=$($pe.Machine)", "dll=$($pe.Dll)")
}
