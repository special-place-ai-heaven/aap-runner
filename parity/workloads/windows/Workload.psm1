# Shared helpers for the P17 Windows and Actions workloads. Windows PowerShell 5.1 and pwsh 7.
# A workload script calls Invoke-Workload with a body. Every tool line goes to stdout (the harness log) with the
# work and repository paths replaced by <work> and <repo>, so logs and first causal errors compare across machines.
# Observed facts go to $env:PARITY_OBS_DIR (or the work folder), never into the hashed artifacts.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:S = $null

function Write-Line([string]$Text) { [Console]::Out.WriteLine($Text) }

function Format-Norm([string]$Text) {
    if ($null -eq $script:S) { return $Text }
    foreach ($p in @(@($script:S.Work, '<work>'), @($script:S.Repo, '<repo>'))) {
        foreach ($form in @($p[0], $p[0].Replace('\', '/'))) {
            $Text = [regex]::Replace($Text, [regex]::Escape($form), $p[1], 'IgnoreCase')
        }
    }
    $Text
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Get-Oracle([string]$Key) {
    # 'versions/cmake' -> the cited value; a group ('env', 'services') comes back whole, its members as {v, src}
    $o = $script:S.Oracle
    foreach ($k in $Key.Split('/')) {
        $p = $o.PSObject.Properties[$k]
        if ($null -eq $p) { throw "oracle has no key $Key" }
        $o = $p.Value
    }
    if ($o.PSObject.Properties['src']) { $o.v } else { $o }
}

function Add-Observation([string]$Name, $Value) { $script:S.Obs[$Name] = [ordered]@{ observed = $Value } }

function Add-Fact {
    # One oracle check. -Match treats Expected as a regex; otherwise case-insensitive equality ($null = absent).
    param([Parameter(Mandatory)][string]$Name, $Observed, $Expected, [switch]$Match)
    $ok = if ($Match) { "$Observed" -match $Expected } else { "$Observed" -eq "$Expected" }
    $script:S.Obs[$Name] = [ordered]@{ observed = $Observed; expected = $Expected; ok = $ok }
    if ($ok) { Write-Line ("ok   {0} = {1}" -f $Name, (Format-Norm "$Observed")) }
    else {
        [void]$script:S.Failures.Add($Name)
        Write-Line ("error: oracle {0} expected '{1}' observed '{2}'" -f $Name, $Expected, (Format-Norm "$Observed"))
    }
}

function ConvertTo-PathNorm([string]$Path) {
    # VsDevCmd builds some entries with doubled separators (Windows Kits\10\\include); compare them collapsed.
    if (-not $Path) { return $Path }
    $Path.Substring(0, 1) + [regex]::Replace($Path.Substring(1), '\\{2,}', '\')
}

function Split-PathList([string]$Value) { @("$Value".Split(';') | Where-Object { $_ } | ForEach-Object { ConvertTo-PathNorm $_ }) }

function Resolve-Exe([string]$Name) {
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { ConvertTo-PathNorm $c.Source } else { $null }
}

function Invoke-Tool {
    # Runs a native tool with merged output echoed (normalized) to the log. Throws on a nonzero exit unless -AllowFail.
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [switch]$AllowFail, [switch]$Quiet)
    if (Test-Path -LiteralPath $Exe -PathType Leaf) { $Exe = (Resolve-Path -LiteralPath $Exe).ProviderPath }
    else {
        $r = Resolve-Exe $Exe
        if (-not $r) { throw "tool not found: $Exe" }
        $Exe = $r
    }
    Write-Line ('> ' + (Format-Norm ("{0} {1}" -f (Split-Path -Leaf $Exe), ($Arguments -join ' '))))
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $eap }
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { Format-Norm $_ })
    if (-not $Quiet) { foreach ($l in $lines) { Write-Line $l } }
    if ($code -ne 0 -and -not $AllowFail) { throw ("{0} exited with code {1}" -f (Split-Path -Leaf $Exe), $code) }
    [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Remove-PathEntries([string]$Name, [string]$Like) {
    # Sabotage helper: drop the entries of a ;-list variable that match a wildcard.
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v) { return }
    $kept = @($v.Split(';') | Where-Object { $_ -and $_ -notlike $Like })
    [Environment]::SetEnvironmentVariable($Name, ($kept -join ';'))
}

function Set-DevEnvSabotage([string]$Sabotage) {
    # Negative controls: the developer environment without the Windows SDK headers or libraries.
    switch ($Sabotage) {
        'no-sdk-include' { Remove-PathEntries 'INCLUDE' '*\Windows Kits\*' }
        'no-sdk-lib' { Remove-PathEntries 'LIB' '*\Windows Kits\*' }
    }
    if ($Sabotage) { Write-Line "sabotage $Sabotage applied" }
}

function Get-VsInstall {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "vswhere.exe not found at $vswhere" }
    $r = Invoke-Tool $vswhere @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-format', 'json') -Quiet
    $vs = @($r.Text | ConvertFrom-Json)
    if (-not $vs.Count) { throw 'vswhere found no Visual Studio with the x64 C++ tools' }
    [pscustomobject]@{ VsWhere = $vswhere; Path = $vs[0].installationPath; Version = $vs[0].installationVersion; ProductId = $vs[0].productId }
}

function Enter-DevEnv {
    # VsDevCmd.bat into this process's environment (children inherit it). Lines VsDevCmd prints go to the log.
    param([string]$Arch = 'x64', [string]$VcVarsVer = '', [string]$WinSdk = '')
    $vs = Get-VsInstall
    $a = @("-arch=$Arch", '-host_arch=x64', '-no_logo')
    if ($VcVarsVer) { $a += "-vcvars_ver=$VcVarsVer" }
    if ($WinSdk) { $a += "-winsdk=$WinSdk" }
    $bat = Join-Path $env:TEMP 'parity-devenv.cmd'
    $devcmd = Join-Path $vs.Path 'Common7\Tools\VsDevCmd.bat'
    [IO.File]::WriteAllLines($bat, [string[]]@(('@call "{0}" {1}' -f $devcmd, ($a -join ' ')), '@if errorlevel 1 exit /b 1', '@echo ===PARITY-ENV===', '@set'))
    $env:VSCMD_SKIP_SENDTELEMETRY = '1'
    Write-Line ('> VsDevCmd.bat ' + ($a -join ' '))
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = @(& $env:ComSpec /d /c $bat 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $eap }
    $i = [array]::IndexOf($raw, '===PARITY-ENV===')
    $pre = if ($i -lt 0) { $raw } elseif ($i -gt 0) { $raw[0..($i - 1)] } else { @() }
    foreach ($l in $pre) { Write-Line (Format-Norm $l) }
    if ($i -lt 0) { throw "VsDevCmd.bat $($a -join ' ') failed" }
    foreach ($l in $raw[($i + 1)..($raw.Count - 1)]) {
        $k = $l.IndexOf('=')
        if ($k -gt 0) { [Environment]::SetEnvironmentVariable($l.Substring(0, $k), $l.Substring($k + 1)) }
    }
    $vs
}

function Get-PeInfo([string]$Path) {
    $b = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $machine = [int][BitConverter]::ToUInt16($b, $pe + 4)
    $chars = [int][BitConverter]::ToUInt16($b, $pe + 22)
    $subsys = [int][BitConverter]::ToUInt16($b, $pe + 24 + 68)  # same offset in PE32 and PE32+
    $m = @{ 0x8664 = 'x64'; 0x14c = 'x86'; 0xAA64 = 'arm64' }
    $s = @{ 2 = 'gui'; 3 = 'console' }
    [pscustomobject]@{
        Machine   = $(if ($m.ContainsKey($machine)) { $m[$machine] } else { '0x{0:x}' -f $machine })
        Subsystem = $(if ($s.ContainsKey($subsys)) { $s[$subsys] } else { "$subsys" })
        Dll       = [bool]($chars -band 0x2000)
    }
}

function Get-PeImports([string]$Path) {
    # Needs the developer environment (dumpbin). Lower-case module names.
    $r = Invoke-Tool dumpbin.exe @('/nologo', '/dependents', $Path) -Quiet
    @($r.Lines | Where-Object { $_ -match '^\s+(\S+\.(dll|exe))\s*$' } | ForEach-Object { $Matches[1].ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-ZipEntries([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try { @($z.Entries | ForEach-Object { $_.FullName } | Sort-Object) } finally { $z.Dispose() }
}

function Find-Uninstall([string]$DisplayNameLike) {
    # Install location of a program as Windows records it (how consumers find tools that are not on PATH).
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $DisplayNameLike -and $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation } |
        Select-Object -First 1
}

function Copy-Source([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    Copy-Item -Path (Join-Path $From '*') -Destination $To -Recurse -Force
}

function Write-Report([string[]]$Lines) {
    # The hashed artifact: deterministic facts only (no versions, paths or times).
    Write-Utf8 (Join-Path $script:S.Work 'report.txt') (($Lines -join "`n") + "`n")
    foreach ($l in $Lines) { Write-Line "report $l" }
}

function Invoke-Workload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Work, [string]$Sabotage = '', [Parameter(Mandatory)][scriptblock]$Body)
    $work = (Resolve-Path -LiteralPath $Work).ProviderPath
    $PSCmdlet.SessionState.PSVariable.Set('Work', $work)  # the calling script's $Work becomes absolute for its body
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).ProviderPath
    $profileName = if ($env:PARITY_PROFILE) { $env:PARITY_PROFILE } else { 'windows-2025-vs2026' }
    $tmp = Join-Path $work 'tmp'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $env:TEMP = $tmp
    $env:TMP = $tmp
    $script:S = @{
        Id = $Id; Work = $work; Repo = $repo; Sabotage = $Sabotage; Profile = $profileName
        Oracle = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "oracle\$profileName.json") | ConvertFrom-Json)
        Obs = [ordered]@{}; Failures = New-Object Collections.ArrayList
    }
    Write-Line ("workload {0} profile={1} sabotage={2}" -f $Id, $profileName, $(if ($Sabotage) { $Sabotage } else { 'none' }))
    $code = 1
    try {
        Set-Location -LiteralPath $work
        & $Body
        if ($script:S.Failures.Count) { Write-Line ("workload {0}: {1} oracle check(s) not met" -f $Id, $script:S.Failures.Count) }
        else { $code = 0; Write-Line ("workload {0}: all oracle checks met" -f $Id) }
    }
    catch {
        [void]$script:S.Failures.Add('exception')
        Write-Line ('error: ' + (Format-Norm $_.Exception.Message))
    }
    finally {
        $dir = if ($env:PARITY_OBS_DIR) { $env:PARITY_OBS_DIR } else { $work }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $doc = [ordered]@{ id = $Id; profile = $profileName; sabotage = $Sabotage; failures = @($script:S.Failures); facts = $script:S.Obs }
        Write-Utf8 (Join-Path $dir (($Id -replace '/', '__') + '.observed.json')) ($doc | ConvertTo-Json -Depth 8)
    }
    exit $code
}

Export-ModuleMember -Function Write-Line, Format-Norm, Write-Utf8, Get-Oracle, Add-Observation, Add-Fact, ConvertTo-PathNorm, Split-PathList, Resolve-Exe, Invoke-Tool,
    Remove-PathEntries, Set-DevEnvSabotage, Get-VsInstall, Enter-DevEnv, Get-PeInfo, Get-PeImports, Get-ZipEntries, Find-Uninstall, Copy-Source,
    Write-Report, Invoke-Workload
