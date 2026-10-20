# windows/msvc-*: MSVC C and C++ inside the developer environment for one target. Exercises the Windows SDK and UCRT
# headers and import libraries, rc.exe resources, lib.exe static libraries, a system library (advapi32), /MT and /MD
# CRTs and debug symbols (PDB), then runs the programs (arm64 is cross-built only: an x64 host cannot run it).
param(
    [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '',
    [ValidateSet('x64', 'x86', 'arm64')][string]$Arch = 'x64', [string]$VcVarsVer = ''
)
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    Enter-DevEnv -Arch $Arch -VcVarsVer $VcVarsVer | Out-Null
    Add-Fact 'devenv.VSCMD_ARG_TGT_ARCH' $env:VSCMD_ARG_TGT_ARCH $Arch
    if ($VcVarsVer) { Add-Fact 'devenv.VCToolsVersion' $env:VCToolsVersion ('^' + [regex]::Escape($VcVarsVer) + '\.') -Match }
    else { Add-Observation 'devenv.VCToolsVersion' $env:VCToolsVersion }
    Set-DevEnvSabotage $Sabotage

    Copy-Source (Join-Path $PSScriptRoot 'src') (Join-Path $Work 'build')
    Set-Location -LiteralPath (Join-Path $Work 'build')
    Invoke-Tool cl.exe @('/nologo', '/c', '/W4', '/WX', '/MT', 'util.c') | Out-Null
    Invoke-Tool lib.exe @('/nologo', '/OUT:util.lib', 'util.obj') | Out-Null
    Invoke-Tool cl.exe @('/nologo', '/W4', '/WX', '/MT', '/Zi', '/Fehello_c.exe', 'hello.c', 'util.lib', 'advapi32.lib', '/link', '/DEBUG', '/INCREMENTAL:NO') | Out-Null
    Invoke-Tool rc.exe @('/nologo', '/fo', 'version.res', 'version.rc') | Out-Null
    Invoke-Tool cl.exe @('/nologo', '/W4', '/WX', '/EHsc', '/std:c++17', '/MD', '/O2', '/Fehello_cpp.exe', 'hello.cpp', 'version.res') | Out-Null

    $bits = if ($Arch -eq 'x86') { 32 } else { 64 }
    $want = @{
        'hello_c'   = "hello from msvc c bits=$bits twice=42 user_lookup=ok"
        'hello_cpp' = "hello from msvc c++ bits=$bits sum=10 caught=boom cwd=ok tick=ok"
    }
    $report = @("arch=$Arch")
    $imp = @{}
    foreach ($p in 'hello_c', 'hello_cpp') {
        $exe = Join-Path (Get-Location) "$p.exe"
        if ($Arch -eq 'arm64') { $out = 'not-run (arm64 binary on an x64 host)' }
        else { $out = (Invoke-Tool $exe).Lines -join ' '; Add-Fact "$p.output" $out $want[$p] }
        $pe = Get-PeInfo $exe
        $imp[$p] = Get-PeImports $exe
        Add-Observation "$p.imports" $imp[$p]
        Add-Fact "$p.machine" $pe.Machine $Arch
        Add-Fact "$p.subsystem" $pe.Subsystem 'console'
        $report += "$p.output=$out", "$p.machine=$($pe.Machine)", "$p.subsystem=$($pe.Subsystem)"
    }
    # /MT links the CRT statically; /MD imports it. advapi32 is the system library hello.c links.
    Add-Fact 'hello_c.imports.advapi32' ($imp['hello_c'] -contains 'advapi32.dll') $true
    Add-Fact 'hello_c.static_crt' ($imp['hello_c'] -contains 'vcruntime140.dll') $false
    Add-Fact 'hello_cpp.dynamic_crt' ($imp['hello_cpp'] -contains 'vcruntime140.dll') $true
    $report += "hello_c.imports.advapi32=$($imp['hello_c'] -contains 'advapi32.dll')", "hello_c.static_crt=$(-not ($imp['hello_c'] -contains 'vcruntime140.dll'))",
        "hello_cpp.dynamic_crt=$($imp['hello_cpp'] -contains 'vcruntime140.dll')"
    $pdb = Test-Path -LiteralPath 'hello_c.pdb'
    Add-Fact 'hello_c.pdb' $pdb $true
    $desc = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path (Get-Location) 'hello_cpp.exe')).FileDescription
    Add-Fact 'hello_cpp.version_resource' $desc 'AAP parity MSVC fixture'
    $report += "hello_c.pdb=$(if ($pdb) { 'present' } else { 'missing' })", "hello_cpp.description=$desc"
    Write-Report $report
}
