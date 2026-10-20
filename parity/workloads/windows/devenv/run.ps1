# windows/vs-devenv: Visual Studio discovery and developer environment, the way hosted jobs must do it (vswhere,
# then VsDevCmd). Before: no MSVC compiler on PATH and link.exe is Git's. After: SDK and MSVC paths, tools and libraries.
# Sabotage missing-winsdk asks VsDevCmd for a Windows SDK the profile does not have.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    $vs = Get-VsInstall
    if (-not $Sabotage) {
        # a negative control isolates its sabotage; unrelated drift is the positive run's job
        foreach ($tool in 'cl.exe', 'msbuild.exe', 'link.exe', 'clang-cl.exe', 'cmake.exe', 'ninja.exe') {
            Add-Fact "bare_path.$tool" (Resolve-Exe $tool) (Get-Oracle "bare_path/$tool")
        }
        foreach ($n in 'VCINSTALLDIR', 'VSINSTALLDIR', 'VSCMD_VER', 'INCLUDE', 'LIB', 'LIBPATH', 'Platform') {
            Add-Fact "env.$n" ([Environment]::GetEnvironmentVariable($n)) (Get-Oracle "env/$n")
        }
        Add-Fact 'vs.installationVersion' $vs.Version (Get-Oracle 'visual_studio/installationVersion')
        Add-Fact 'vs.installationPath' $vs.Path (Get-Oracle 'visual_studio/installationPath')
        foreach ($c in (Get-Oracle 'visual_studio/components')) {
            $r = Invoke-Tool $vs.VsWhere @('-latest', '-products', '*', '-requires', $c, '-property', 'installationPath') -Quiet
            Add-Fact "vs.component.$c" ($r.Lines | Select-Object -First 1) $vs.Path
        }
    }

    $sdk = Get-Oracle 'windows_sdk'
    $winsdk = if ($Sabotage -eq 'missing-winsdk') { '10.0.99999.0' } else { '' }
    Enter-DevEnv -Arch x64 -WinSdk $winsdk | Out-Null

    Add-Fact 'devenv.WindowsSDKVersion' ("$env:WindowsSDKVersion".TrimEnd('\')) $sdk
    Add-Fact 'devenv.UCRTVersion' $env:UCRTVersion $sdk
    Add-Fact 'devenv.WindowsSdkDir' $env:WindowsSdkDir '\\Windows Kits\\10\\$' -Match
    Add-Fact 'devenv.VSCMD_ARG_TGT_ARCH' $env:VSCMD_ARG_TGT_ARCH 'x64'
    Add-Fact 'devenv.VCToolsInstallDir' $env:VCToolsInstallDir ('^' + [regex]::Escape($vs.Path) + '\\VC\\Tools\\MSVC\\14\.\d+\.\d+\\$') -Match
    Add-Observation 'devenv.VCToolsVersion' $env:VCToolsVersion
    $kits = "$env:WindowsSdkDir"
    foreach ($d in 'ucrt', 'um', 'shared', 'winrt') {
        Add-Fact "devenv.INCLUDE.$d" ((Split-PathList $env:INCLUDE) -contains (Join-Path $kits "include\$sdk\$d")) $true
    }
    foreach ($d in 'ucrt\x64', 'um\x64') {
        Add-Fact "devenv.LIB.$d" ((Split-PathList $env:LIB) -contains (Join-Path $kits "lib\$sdk\$d")) $true
    }
    Add-Fact 'sdk.windows.h' (Test-Path -LiteralPath (Join-Path $kits "include\$sdk\um\windows.h")) $true
    Add-Fact 'sdk.kernel32.lib' (Test-Path -LiteralPath (Join-Path $kits "lib\$sdk\um\x64\kernel32.lib")) $true
    Add-Fact 'sdk.ucrt.lib' (Test-Path -LiteralPath (Join-Path $kits "lib\$sdk\ucrt\x64\ucrt.lib")) $true
    $vcbin = Join-Path "$env:VCToolsInstallDir" 'bin\Hostx64\x64'
    foreach ($t in 'cl.exe', 'link.exe', 'lib.exe', 'dumpbin.exe', 'nmake.exe') {
        Add-Fact "devenv.path.$t" (Resolve-Exe $t) (Join-Path $vcbin $t)
    }
    foreach ($t in 'rc.exe', 'mt.exe') {
        Add-Fact "devenv.path.$t" (Resolve-Exe $t) (Join-Path $kits "bin\$sdk\x64\$t")
    }
    Add-Fact 'devenv.path.msbuild.exe' (Resolve-Exe 'msbuild.exe') ('^' + [regex]::Escape($vs.Path) + '\\MSBuild\\Current\\Bin\\') -Match
}
