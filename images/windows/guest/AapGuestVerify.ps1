# Post-build verification inside a FRESH guest booted from the sealed disk, run as the job user the answer file created
# (runneradmin, a local administrator, as on the hosted image). Windows PowerShell 5.1. Prints one JSON reply line.
#  1. Upstream image tests: the pinned tests from the P03-staged archive, run by the upstream RunAll-Tests.ps1.
#  2. Full job inventory: tools/parity-certify/probe/windows.ps1 (P05), Docker included.
#  3. Native toolchain discovery the way a job does it: vswhere, then the VS developer environment (VsDevCmd), then
#     cl/link/clang-cl/lld-link/rc/msbuild/cmake/ninja and the Windows SDK, and real compile, link, run and resource builds.
# Downloads nothing. All output except the reply goes to files under D:\aap-verify.
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [string]$WorkRoot = 'C:\aap-build',
    [string]$OutRoot = 'D:\aap-verify'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-Printable([string]$Text) {
    if ($null -eq $Text) { return '' }
    $t = [regex]::Replace($Text, '[^\x20-\x7e]', '?')
    if ($t.Length -gt 400) { $t = $t.Substring(0, 400) }
    return $t
}
function Get-Sha256([string]$Path) {
    $h = [Security.Cryptography.SHA256]::Create(); $s = [IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToLowerInvariant() } finally { $s.Dispose(); $h.Dispose() }
}
function Send-Reply([string]$Status, [string]$Message, $Data) {
    $o = [ordered]@{ schema = 1; phase = 'verify'; status = $Status; message = (Get-Printable $Message) }
    if ($null -ne $Data) { $o["data"] = $Data }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $o -Depth 6 -Compress))
}
function Invoke-Hidden([string]$File, [string[]]$Arguments, [string]$Log) {
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
    return [int]$p.ExitCode
}

try {
    $req = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($RequestPath))
    if ($req.phase -cne 'verify') { throw 'not a verify request' }
    $imageFolder = [string]$req.vars.image_folder
    [void][IO.Directory]::CreateDirectory($OutRoot)
    $work = Join-Path $OutRoot 'work'
    [void][IO.Directory]::CreateDirectory($work)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()

    # 1. Upstream tests. The sealed image keeps the upstream test module (TestsHelpers); the tests come from the archive.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $src = Join-Path $OutRoot 'src'
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $WorkRoot 'runner-images.zip'), $src)
    $top = @(Get-ChildItem -LiteralPath $src -Directory)
    if ($top.Count -ne 1) { throw 'the archive must hold exactly one top-level folder' }
    $tests = Join-Path $imageFolder 'tests'
    if (-not (Test-Path -LiteralPath $tests)) { Copy-Item -LiteralPath (Join-Path $top[0].FullName 'images\windows\scripts\tests') -Destination $tests -Recurse }
    $results = Join-Path $tests 'testResults.xml'
    if (Test-Path -LiteralPath $results) { Remove-Item -LiteralPath $results -Force }
    $env:IMAGE_FOLDER = $imageFolder
    [void](Invoke-Hidden $ps @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $tests 'RunAll-Tests.ps1')`"") (Join-Path $OutRoot 'upstream-tests.log'))
    $total = 0; $failed = 0; $skipped = 0
    if (Test-Path -LiteralPath $results) {
        $x = [xml][IO.File]::ReadAllText($results)
        $r = $x.SelectSingleNode('/test-results')
        if ($r) {
            $n = { param($name) $v = $r.GetAttribute($name); if ($v) { [int]$v } else { 0 } }
            $total = & $n 'total'
            $failed = (& $n 'failures') + (& $n 'errors') + (& $n 'invalid')
            $skipped = (& $n 'not-run') + (& $n 'skipped') + (& $n 'ignored') + (& $n 'inconclusive')
        }
    } else { $failed = 1 }
    $upstream = [ordered]@{ total = $total; passed = [Math]::Max(0, $total - $failed - $skipped); failed = $failed; skipped = $skipped }

    # 2. Inventory with the P05 probe.
    $inv = Join-Path $OutRoot 'job-inventory.json'
    [void](Invoke-Hidden $ps @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $WorkRoot 'probe-windows.ps1')`"", '-OutFile', "`"$inv`"") (Join-Path $OutRoot 'probe.log'))
    $invSha = $null
    if (Test-Path -LiteralPath $inv) { $invSha = Get-Sha256 $inv }

    # 3. Toolchain discovery through the developer environment, as hosted jobs do it (no global PATH of every compiler).
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = $null
    if (Test-Path -LiteralPath $vswhere) { $vs = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1) }
    $found = @{}
    $sdk = ''
    if ($vs) {
        [IO.File]::WriteAllText((Join-Path $work 'res.rc'), "STRINGTABLE`r`nBEGIN`r`n  1 `"aap`"`r`nEND`r`n", [Text.Encoding]::ASCII)
        $hello = Join-Path $WorkRoot 'hello.c'
        $cmd = @(
            '@echo off'
            "call `"$vs\Common7\Tools\VsDevCmd.bat`" -arch=x64 -host_arch=x64 -no_logo >nul 2>&1"
            "cd /d `"$work`""
            'where cl.exe >nul 2>&1 && echo AAP:cl'
            'where link.exe >nul 2>&1 && echo AAP:link'
            'where clang-cl.exe >nul 2>&1 && echo AAP:clang_cl'
            'where lld-link.exe >nul 2>&1 && echo AAP:lld_link'
            'where rc.exe >nul 2>&1 && echo AAP:rc'
            'where msbuild.exe >nul 2>&1 && echo AAP:msbuild'
            'where cmake.exe >nul 2>&1 && echo AAP:cmake'
            'where ninja.exe >nul 2>&1 && echo AAP:ninja'
            'if defined WindowsSdkDir if exist "%WindowsSdkDir%Include\%WindowsSDKVersion%um\windows.h" echo AAP:windows_sdk'
            'echo AAP:sdk_version=%WindowsSDKVersion%'
            "cl /nologo `"$hello`" /Fe:hello_msvc.exe >nul 2>&1 && hello_msvc.exe >nul 2>&1 && echo AAP:hello_msvc"
            "clang-cl /nologo `"$hello`" /Fe:hello_clang.exe >nul 2>&1 && hello_clang.exe >nul 2>&1 && echo AAP:hello_clang_cl"
            'rc /nologo res.rc >nul 2>&1 && if exist res.res echo AAP:resource_compile'
        )
        [IO.File]::WriteAllText((Join-Path $work 'discover.cmd'), ($cmd -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
        $log = Join-Path $OutRoot 'discover.log'
        [void](Invoke-Hidden (Join-Path $env:SystemRoot 'System32\cmd.exe') @('/d', '/c', "`"$(Join-Path $work 'discover.cmd')`"") $log)
        foreach ($line in [IO.File]::ReadAllLines($log)) {
            if ($line -match '^AAP:sdk_version=(.*)$') { $sdk = $Matches[1].Trim().TrimEnd('\') }
            elseif ($line -match '^AAP:([a-z_]+)\s*$') { $found[$Matches[1]] = $true }
        }
    }
    $discovery = [ordered]@{ vswhere = [bool]$vs }
    foreach ($k in 'cl', 'link', 'clang_cl', 'lld_link', 'rc', 'msbuild', 'cmake', 'ninja', 'windows_sdk', 'hello_msvc', 'hello_clang_cl', 'resource_compile') { $discovery[$k] = [bool]$found[$k] }
    $discovery.job_user_admin = $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $data = [ordered]@{ upstream_tests = $upstream; discovery = $discovery; sdk_version = $(if ($sdk -match '^10\.0\.[0-9]{5}\.[0-9]{1,4}$') { $sdk } else { '' }); inventory_sha256 = $invSha }
    Send-Reply 'ok' '' $data
    exit 0
} catch {
    Send-Reply 'failed' $_.Exception.Message $null
    exit 0
}
