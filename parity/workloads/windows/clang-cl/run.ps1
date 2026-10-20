# windows/clang-cl: LLVM clang-cl and lld-link from PATH in a plain job environment (no developer environment). clang-cl
# finds the MSVC headers and Windows SDK itself; lld-link links against them. Sabotage no-sdk-include sets INCLUDE to an
# empty folder, which clang-cl honours instead of its own discovery, so the SDK headers are missing.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $clang = Resolve-Exe 'clang-cl.exe'
    if (-not $Sabotage) { Add-Fact 'bare_path.clang-cl.exe' $clang (Get-Oracle 'bare_path/clang-cl.exe') }
    if (-not $clang) { throw 'clang-cl.exe not found on PATH' }
    if ($Sabotage -eq 'no-sdk-include') {
        $empty = Join-Path $Work 'empty-include'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        $env:INCLUDE = $empty
        Write-Line 'sabotage no-sdk-include applied'
    }
    Copy-Source (Join-Path $PSScriptRoot '..\msvc\src') (Join-Path $Work 'build')
    Set-Location -LiteralPath (Join-Path $Work 'build')
    Invoke-Tool $clang @('/nologo', '/W4', '/WX', '/MT', '-fuse-ld=lld', '/Fehello_c.exe', 'hello.c', 'util.c', 'advapi32.lib') | Out-Null
    Invoke-Tool $clang @('/nologo', '/W4', '/WX', '/EHsc', '/std:c++17', '/MD', '/O2', '-fuse-ld=lld', '/Fehello_cpp.exe', 'hello.cpp') | Out-Null

    $want = @{
        'hello_c'   = 'hello from msvc c bits=64 twice=42 user_lookup=ok'
        'hello_cpp' = 'hello from msvc c++ bits=64 sum=10 caught=boom cwd=ok tick=ok'
    }
    $report = @('compiler=clang-cl', 'linker=lld-link')
    foreach ($p in 'hello_c', 'hello_cpp') {
        $out = (Invoke-Tool (Join-Path (Get-Location) "$p.exe")).Lines -join ' '
        $pe = Get-PeInfo "$p.exe"
        Add-Fact "$p.output" $out $want[$p]
        Add-Fact "$p.machine" $pe.Machine 'x64'
        $report += "$p.output=$out", "$p.machine=$($pe.Machine)", "$p.subsystem=$($pe.Subsystem)"
    }
    Write-Report $report
}
