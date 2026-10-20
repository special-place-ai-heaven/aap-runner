# windows/cmake-*: configure, build, test (ctest) and package (cpack ZIP) one C/C++ project.
#   -Generator ninja: inside the developer environment with Ninja and cl (the CMake and Ninja that environment puts first).
#   -Generator vs: plain job environment, the PATH CMake with the Visual Studio 18 2026 generator (MSBuild finds the SDK).
# Sabotage no-sdk-lib strips the SDK libraries from the developer environment; missing-winsdk asks MSBuild for an SDK
# version the profile does not have (WindowsTargetPlatformVersion: CMAKE_SYSTEM_VERSION only caps the version CMake picks).
param(
    [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '',
    [Parameter(Mandatory)][ValidateSet('ninja', 'vs')][string]$Generator
)
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $gen = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release')
    $cfg = @()
    $buildArgs = @()
    $exe = 'build\calc_app.exe'
    if ($Generator -eq 'ninja') {
        Enter-DevEnv -Arch x64 | Out-Null
        Set-DevEnvSabotage $Sabotage
    }
    else {
        $gen = @('-G', 'Visual Studio 18 2026', '-A', 'x64')
        $buildArgs = @('--config', 'Release')
        if ($Sabotage -eq 'missing-winsdk') { $buildArgs += '--', '/p:WindowsTargetPlatformVersion=10.0.99999.0'; Write-Line 'sabotage missing-winsdk applied' }
        $cfg = @('-C', 'Release')
        $exe = 'build\Release\calc_app.exe'
    }
    $cmake = Resolve-Exe 'cmake.exe'
    if (-not $cmake) { throw 'cmake.exe not found on PATH' }
    Add-Observation 'cmake.path' $cmake
    if ($Generator -eq 'vs' -and -not $Sabotage) { Add-Fact 'bare_path.cmake.exe' $cmake (Get-Oracle 'bare_path/cmake.exe') }
    $bin = Split-Path -Parent $cmake

    Copy-Source (Join-Path $PSScriptRoot 'src') (Join-Path $Work 'src')
    Invoke-Tool $cmake (@('-S', 'src', '-B', 'build') + $gen) | Out-Null
    Invoke-Tool $cmake (@('--build', 'build') + $buildArgs) | Out-Null
    $t = Invoke-Tool (Join-Path $bin 'ctest.exe') (@('--test-dir', 'build', '--output-on-failure') + $cfg)
    # CTest 4.x drops ", 0 tests failed" when nothing failed: "100% tests passed out of 1"
    $tests = if ($t.Text -match '(\d+)% tests passed(?:, (\d+) tests failed)? out of (\d+)') { "$($Matches[3]) run, $(if ($Matches[2]) { $Matches[2] } else { 0 }) failed" } else { 'unparsed' }
    Add-Fact 'ctest' $tests '1 run, 0 failed'
    Invoke-Tool (Join-Path $bin 'cpack.exe') (@('--config', 'build\CPackConfig.cmake', '-B', 'pkg') + $cfg) | Out-Null

    $out = (Invoke-Tool (Join-Path $Work $exe)).Lines -join ' '
    Add-Fact 'calc_app.output' $out 'hello from cmake calc add=5 cpus=ok'
    $pe = Get-PeInfo $exe
    Add-Fact 'calc_app.machine' $pe.Machine 'x64'
    $entries = Get-ZipEntries 'pkg\aap-parity-cmake.zip'
    Add-Fact 'cpack.contains_app' ($entries -contains 'aap-parity-cmake/bin/calc_app.exe') $true
    Write-Report (@("generator=$Generator", "calc_app.output=$out", "calc_app.machine=$($pe.Machine)", "ctest=$tests") + ($entries | ForEach-Object { "cpack.entry=$_" }))
}
