# zccache guest integration (P13), Windows guest. Windows PowerShell 5.1 and PowerShell 7.
#   Install-AapZcCache       image build: verify the P03-staged archive and its members, install bin + toolchain identities
#   Initialize-AapZcJob      guest agent, before Actions starts: bounded per-job root, wrappers for qualified pairs only
#   Connect-AapZcSharedRoot  guest agent, on the host's bind: attach the shared root the host chose, or refuse
#   Get-AapZcState           guest agent status/collect: qualified, direct, disabled, degraded or unknown, plus byte counts
#   Invoke-AapZcShim         zcshim.ps1: per compiler call, zccache for qualified pairs, else the compiler directly
# Any wrapper, daemon or budget problem runs the compiler directly (contract rule 7). Nothing here deletes a file from a
# cache root: retention is the daemon's, and a root over budget stops being used. Every safety check carries a
# SAFETY:<id> tag; tests/guests/cache/mutate.py breaks each one and expects a test to fail.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

$script:Platform = 'windows-x86_64'
# The P04 harness's rules (parity/cache/qualification/harness/qualify.ps1): names that look like credentials, and values
# that carry URL credentials. The daemon and its crash dumps inherit the environment of the call that starts it.
$script:SecretName = '(?i)token|secret|pass|credential|jit|jwt|private_?key|(^|_)(api_?)?key$|pem$|(^|_)(pat|auth)($|_)|_pwd$'
$script:UrlCredential = '://[^/@\s]*:[^/@\s]*@'
$script:Compilers = @('rustc', 'clang', 'clang++', 'clang-cl', 'cl', 'link', 'lld-link')
# A shared root's namespace: binding, disk marker and the guest's own identity must agree on every field.
$script:NamespaceKeys = @('repository_id', 'repository', 'trust_class', 'platform', 'toolchain_digest', 'zccache_version')
# The compiler launcher runs zcshim.ps1 under PowerShell 7: Windows PowerShell 5.1's -File refuses a bare '-' argument
# (a compiler reading stdin) before the script runs, which would fail the compile itself.
$script:LauncherShell = $(if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' })
$script:LogLimit = 1MB
$script:UsageEverySeconds = 30
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-AapZcProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Set-AapZcProp($Object, [string]$Name, $Value) {
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value; return }
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-AapZcBytesHash([byte[]]$Bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { -join ($h.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() }
}

function Get-AapZcFileHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Test-AapZcLink([string]$Path) {
    $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $i -and ([int]$i.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Read with every share mode, so a writer can replace the file while a shim is reading it.
function Read-AapZcJson([string]$Path) {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { (New-Object IO.StreamReader($fs, $script:Utf8)).ReadToEnd() | ConvertFrom-Json } finally { $fs.Dispose() }
}

# Readers (the shim) see the old file or the new one, never half of one. A reader that opened the file without
# delete sharing (an older shim, antivirus) only delays the replacement.
function Write-AapZcJson($Object, [string]$Path) {
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 8), $script:Utf8)
        for ($i = 0; ; $i++) {
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
                return
            } catch { if ($i -ge 40) { throw }; Start-Sleep -Milliseconds 50 }
        }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function New-AapZcDir([string]$Path) {
    if (Test-AapZcLink $Path) { throw "AAP_ZC_Link: $Path is a link or junction" }  # SAFETY:WIN-DIR-LINK
    $null = New-Item -ItemType Directory -Path $Path -Force
}

# Bytes below a folder; links and junctions are counted as entries, never followed.
function Measure-AapZcTree([string]$Path) {
    [long]$sum = 0
    if (-not [IO.Directory]::Exists($Path)) { return $sum }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count) {
        $d = $stack.Pop()
        foreach ($e in (New-Object IO.DirectoryInfo($d)).GetFileSystemInfos()) {
            if (([int]$e.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($e -is [IO.DirectoryInfo]) { $stack.Push($e.FullName) } else { $sum += $e.Length }
        }
    }
    return $sum
}

# One argument in CommandLineToArgvW form, so the child sees exactly the argv the shim received.
function ConvertTo-AapZcArg([string]$Arg) {
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    $bs = 0
    [void]$sb.Append('"')
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq [char]'\') { $bs++; continue }
        if ($c -eq [char]'"') { [void]$sb.Append([char]'\', 2 * $bs + 1); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs) { [void]$sb.Append([char]'\', $bs); $bs = 0 }
        [void]$sb.Append($c)
    }
    if ($bs) { [void]$sb.Append([char]'\', 2 * $bs) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Runs a program. -Capture: hidden, output captured as bytes, and with -TimeoutSeconds killed (TimedOut) when it runs
# longer. Otherwise the program shares this process's console and standard handles, as a direct compiler must (the
# shim always runs in a console, so no window appears).
function Invoke-AapZcProcess {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [System.Collections.IDictionary]$Environment, [switch]$Capture, [int]$TimeoutSeconds = 0)
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $FilePath
    $si.Arguments = (@($Arguments | ForEach-Object { ConvertTo-AapZcArg $_ }) -join ' ')
    $si.UseShellExecute = $false
    $si.CreateNoWindow = [bool]$Capture
    $si.RedirectStandardOutput = [bool]$Capture
    $si.RedirectStandardError = [bool]$Capture
    if ($null -ne $Environment) {
        $si.EnvironmentVariables.Clear()
        foreach ($k in $Environment.Keys) { $si.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
    }
    $p = [System.Diagnostics.Process]::Start($si)
    try {
        $r = [pscustomobject]@{ ExitCode = $null; TimedOut = $false; Stdout = $null; Stderr = $null }
        if (-not $Capture) { $p.WaitForExit(); $r.ExitCode = $p.ExitCode; return $r }
        $out = New-Object IO.MemoryStream; $err = New-Object IO.MemoryStream
        $t1 = $p.StandardOutput.BaseStream.CopyToAsync($out)
        $t2 = $p.StandardError.BaseStream.CopyToAsync($err)
        if (-not $p.WaitForExit($(if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { -1 }))) {
            try { $p.Kill() } catch { $null = $_ }
            $r.TimedOut = $true
            return $r
        }
        # A grandchild that inherited the pipes (a daemon this call started) must not hold the call open.
        [void]$t1.Wait(10000); [void]$t2.Wait(10000)
        $r.ExitCode = $p.ExitCode; $r.Stdout = $out.ToArray(); $r.Stderr = $err.ToArray()
        return $r
    } finally { $p.Dispose() }
}

# The environment a zccache call (and so a daemon it may start) gets: this process's, minus every inherited ZCCACHE_*
# variable and anything credential-shaped, plus exactly the root's own settings.
function Get-AapZcChildEnv($Root) {
    $envOut = New-Object System.Collections.Specialized.OrderedDictionary
    $all = [Environment]::GetEnvironmentVariables()
    foreach ($k in $all.Keys) {
        $n = [string]$k
        if ($n -like 'ZCCACHE_*') { continue }  # SAFETY:WIN-ENV-ZCCACHE
        if ($n -match $script:SecretName -or [string]$all[$k] -match $script:UrlCredential) { continue }  # SAFETY:WIN-ENV-SECRET
        $envOut[$n] = [string]$all[$k]
    }
    $envOut['ZCCACHE_CACHE_DIR'] = [string](Get-AapZcProp $Root 'dir')
    $envOut['ZCCACHE_MODE'] = 'COPY'  # SAFETY:WIN-COPY-MODE (hardlink delivery is off until proven, retention.md 6)
    $envOut['ZCCACHE_CACHE_SIZE_BYTES'] = [string](Get-AapZcProp $Root 'artifact_budget_bytes')  # SAFETY:WIN-BUDGET-SET
    return $envOut
}

function Get-AapZcPlatform([string]$WrappersPath) {
    $w = Read-AapZcJson $WrappersPath
    $plat = Get-AapZcProp (Get-AapZcProp $w 'platforms') $script:Platform
    if ($null -eq $plat) { throw "AAP_ZC_Wrappers: $WrappersPath has no $($script:Platform) entry" }
    [pscustomobject]@{ Version = $w.zccache.version; Platform = $plat }
}

# The installed zccache: always <install>\bin\<pinned member>, never a path from the job's config.
function Get-AapZcBinary([string]$InstallDir) {
    Join-Path (Join-Path $InstallDir 'bin') (Get-AapZcPlatform (Join-Path $InstallDir 'wrappers.json')).Platform.members[0].name
}

function Install-AapZcCache {
    <# Image build. Archive and Provenance come from P03 staging (images/common, entry
       zccache-x86_64-pc-windows-msvc); nothing here downloads. Toolchains is a JSON document
       {"toolchains":[{"compiler","compiler_version","path"}]} naming the image's compilers. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Provenance,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$Toolchains,
        [string]$Wrappers = (Join-Path (Split-Path -Parent $PSScriptRoot) 'wrappers.json')
    )
    $w = Get-AapZcPlatform $Wrappers
    $plat = $w.Platform
    $prov = Read-AapZcJson $Provenance
    $provOk = ((Get-AapZcProp $prov 'schema') -eq 'aap-provenance/1' -and (Get-AapZcProp $prov 'outcome') -eq 'accepted' -and
        (Get-AapZcProp (Get-AapZcProp $prov 'hash') 'verified') -eq $true -and (Get-AapZcProp $prov 'staging_check') -eq 'strict' -and
        (Get-AapZcProp $prov 'name') -eq $plat.acquisition_entry -and (Get-AapZcProp $prov 'version') -eq $w.Version -and
        (Get-AapZcProp $prov 'file_name') -eq $plat.archive -and (Get-AapZcProp $prov 'sha256') -eq $plat.archive_sha256)
    if (-not $provOk) { throw 'AAP_ZC_Provenance: the archive was not accepted and verified by a strict P03 run for this pin' }  # SAFETY:WIN-PROVENANCE
    # Hash and unpack the same bytes, so the archive cannot change between the check and the use.
    $bytes = [IO.File]::ReadAllBytes($Archive)
    if ($bytes.Length -ne [long]$plat.archive_bytes -or (Get-AapZcBytesHash $bytes) -ne $plat.archive_sha256) {  # SAFETY:WIN-ARCHIVE-HASH
        throw 'AAP_ZC_ArchiveHash: the archive is not the pinned release archive'
    }
    $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $bytes)), [IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($e in $zip.Entries) {
            $n = $e.FullName
            $isLink = ((($e.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000)
            if ($n -match '(^|[\\/])\.\.([\\/]|$)' -or $n -match '^[\\/]' -or $n.Contains(':') -or $isLink) {  # SAFETY:WIN-ZIP-MEMBER
                throw "AAP_ZC_ArchiveMember: refused member '$n' (absolute, parent segment or link)"
            }
        }
        $members = @{}
        foreach ($m in $plat.members) {
            $e = $zip.GetEntry($m.path)
            if ($null -eq $e) { throw "AAP_ZC_ArchiveMember: $($m.path) is missing" }
            $ms = New-Object IO.MemoryStream
            $s = $e.Open()
            try { $s.CopyTo($ms) } finally { $s.Dispose() }
            $b = $ms.ToArray()
            if ($b.Length -ne [long]$m.bytes -or (Get-AapZcBytesHash $b) -ne $m.sha256) { throw "AAP_ZC_MemberHash: $($m.path) is not the pinned member" }  # SAFETY:WIN-MEMBER-HASH
            $members[$m.name] = $b
        }
    } finally { $zip.Dispose() }

    New-AapZcDir $InstallDir
    $bin = Join-Path $InstallDir 'bin'
    New-AapZcDir $bin
    foreach ($name in $members.Keys) {
        $tmp = Join-Path $bin ($name + '.tmp')
        [IO.File]::WriteAllBytes($tmp, $members[$name])
        Move-Item -LiteralPath $tmp -Destination (Join-Path $bin $name) -Force
    }
    foreach ($f in 'AapZcCache.psm1', 'zcshim.ps1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $InstallDir $f) -Force }
    Copy-Item -LiteralPath $Wrappers -Destination (Join-Path $InstallDir 'wrappers.json') -Force

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($t in @((Read-AapZcJson $Toolchains).toolchains)) {
        $p = [string]$t.path
        if ($script:Compilers -notcontains [string]$t.compiler -or -not [IO.Path]::IsPathRooted($p) -or -not [IO.File]::Exists($p) -or (Test-AapZcLink $p)) {
            throw "AAP_ZC_Toolchain: refused toolchain entry $($t.compiler) at '$p'"
        }
        $fi = New-Object IO.FileInfo($p)
        $list.Add([ordered]@{ compiler = [string]$t.compiler; compiler_version = [string]$t.compiler_version; path = $fi.FullName
                sha256 = Get-AapZcFileHash $p; bytes = $fi.Length; mtime = $fi.LastWriteTimeUtc.Ticks })
    }
    Write-AapZcJson ([ordered]@{ schema = 1; toolchains = $list.ToArray() }) (Join-Path $InstallDir 'toolchains.json')
    Write-AapZcJson ([ordered]@{ schema = 1; zccache = $w.Version; platform = $script:Platform; archive_sha256 = $plat.archive_sha256
            members = @($plat.members | ForEach-Object { [ordered]@{ name = $_.name; sha256 = $_.sha256 } }); toolchain_digest = Get-AapZcToolchainDigest $list.ToArray()
        }) (Join-Path $InstallDir 'install.json')
}

# SHA-256 of the lines compiler|version|sha256, sorted ordinally, joined by LF (no final newline). Same on Linux; the
# installer records it for the image catalog, and a shared root is bound only to the digest the guest verified at boot.
function Get-AapZcToolchainDigest($Toolchains) {
    [string[]]$lines = @($Toolchains | Where-Object { $null -ne $_ } | ForEach-Object { '{0}|{1}|{2}' -f $_.compiler, $_.compiler_version, $_.sha256 })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    Get-AapZcBytesHash ($script:Utf8.GetBytes(($lines -join "`n")))
}

# Every process with its executable, start time and command line (CIM gives command lines in both editions).
function Get-AapZcProcessList {
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{ Id = [int]$p.ProcessId; Path = [string]$p.ExecutablePath; Start = $p.CreationDate; CommandLine = [string]$p.CommandLine }
    }
}

# Daemon candidates for a root being primed: processes running from the installed bin folder, started at or after
# $After, not a recorded daemon, and not a compile client. Every client the shim starts names a recorded compiler on
# its command line, so a wrapped compile running during an attach is never taken for the new root's daemon.
# ponytail: Windows cannot read another process's environment without native code; Linux matches the daemon by its
# ZCCACHE_CACHE_DIR instead. The lab (P22) records the daemon's own command line, which can then be matched exactly.
function Get-AapZcDaemonProcess([string]$BinDir, [datetime]$After, [int[]]$Exclude = @(), $Toolchains) {
    $prefix = $BinDir.TrimEnd('\') + '\'
    $compilers = @($Toolchains | ForEach-Object { [string](Get-AapZcProp $_ 'path') } | Where-Object { $_ })
    foreach ($p in @(Get-AapZcProcessList)) {
        if (-not $p.Path -or -not $p.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $null -eq $p.Start -or $p.Start -lt $After -or $Exclude -contains $p.Id) { continue }
        $line = [string]$p.CommandLine
        if (@($compilers | Where-Object { $line.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) { continue }  # SAFETY:WIN-DAEMON-ID
        $p
    }
}

function Test-AapZcDaemonAlive($Daemon) {
    if ($null -eq $Daemon) { return $false }
    $p = Get-Process -Id ([int](Get-AapZcProp $Daemon 'pid')) -ErrorAction SilentlyContinue
    return ($null -ne $p -and $p.StartTime.ToUniversalTime().Ticks -eq [long](Get-AapZcProp $Daemon 'start'))  # SAFETY:WIN-DAEMON-ALIVE
}

# Starts the root's daemon from this (the agent's) environment, never from a job step. zccache starts its daemon on
# demand (README 379-381); an empty journaled session is the documented call that does it. To confirm in lab.
function Start-AapZcDaemon($Config, [string]$RootId, [string]$InstallDir) {
    $root = Get-AapZcProp $Config.roots $RootId
    New-AapZcDir ([string]$root.dir)
    $zc = Get-AapZcBinary $InstallDir
    $before = [DateTime]::Now.AddSeconds(-2)
    $envVars = Get-AapZcChildEnv $root
    $journal = Join-Path $Config.job_root ('state\prime-' + $RootId + '.jsonl')
    $r = Invoke-AapZcProcess -FilePath $zc -Arguments @('session-start', '--journal', $journal) -Environment $envVars -Capture -TimeoutSeconds 60
    $sid = $null
    if ($r.ExitCode -eq 0) { try { $sid = ($script:Utf8.GetString($r.Stdout) | ConvertFrom-Json).session_id } catch { $null = $_ } }
    if ($sid) { $null = Invoke-AapZcProcess -FilePath $zc -Arguments @('session-end', [string]$sid) -Environment $envVars -Capture -TimeoutSeconds 60 }
    $names = $(if ($Config.roots -is [System.Collections.IDictionary]) { @($Config.roots.Keys) } else { @($Config.roots.PSObject.Properties | ForEach-Object { $_.Name }) })
    $known = @(foreach ($n in $names) { $k = Get-AapZcProp (Get-AapZcProp $Config.roots $n) 'daemon'; if ($k) { [int](Get-AapZcProp $k 'pid') } })
    $d = @(Get-AapZcDaemonProcess -BinDir (Split-Path -Parent $zc) -After $before -Exclude $known -Toolchains (Get-AapZcProp $Config 'toolchains'))
    $p = $(if ($r.ExitCode -eq 0 -and $d.Count -eq 1) { Get-Process -Id $d[0].Id -ErrorAction SilentlyContinue })
    if (-not $p) {
        # A failed start, or none or several candidates: stop every candidate rather than leave an unrecorded daemon on a
        # root this job will not use.
        foreach ($x in $d) { Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue }
        return $false
    }
    Set-AapZcProp $root 'daemon' ([ordered]@{ pid = $p.Id; start = $p.StartTime.ToUniversalTime().Ticks })
    return $true
}

function Get-AapZcConfigPath([string]$JobRoot) { Join-Path $JobRoot 'state\config.json' }

function Initialize-AapZcJob {
    <# Guest agent, before the Actions runner starts. BudgetBytes is the private root's allowance on the scratch disk
       (artifacts, index, metadata, zccache's logs and temp); state\ and shim\ come on top (README). Returns the config;
       writes state\config.json and state\runner.env (KEY=VALUE lines P14 merges into the runner's environment; empty
       when nothing is qualified). SharedRoots lets Connect-AapZcSharedRoot attach a host root at all; it stays off
       until the lab proof for shared roots exists (P04/P22). WrapperTimeoutSeconds bounds each wrapped zccache call. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallDir, [Parameter(Mandatory)][string]$JobRoot, [Parameter(Mandatory)][long]$BudgetBytes,
        [switch]$SharedRoots, [ValidateRange(1, 3600)][int]$WrapperTimeoutSeconds = 60)
    New-AapZcDir $JobRoot
    foreach ($d in 'state', 'roots', 'shim') { New-AapZcDir (Join-Path $JobRoot $d) }
    $w = Get-AapZcPlatform (Join-Path $InstallDir 'wrappers.json')
    $artifactBudget = [long][Math]::Floor($BudgetBytes * 3 / 4)
    $cfg = [ordered]@{
        schema = 1; platform = $script:Platform; install_dir = $InstallDir; job_root = $JobRoot; zccache_version = [string]$w.Version
        shared_roots = [bool]$SharedRoots; wrapper_timeout_seconds = $WrapperTimeoutSeconds
        state = 'direct'; detail = 'no qualified compiler and invocation pair'
        toolchains = @(); toolchain_digest = $null; qualified = @(); active_root = 'private'
        roots = [ordered]@{ private = [ordered]@{ dir = Join-Path $JobRoot 'roots\private'; budget_bytes = $BudgetBytes; artifact_budget_bytes = $artifactBudget; daemon = $null } }
    }
    $envLines = New-Object System.Collections.Generic.List[string]
    $binOk = $true
    foreach ($m in $w.Platform.members) {
        $p = Join-Path $InstallDir ('bin\' + $m.name)
        if (-not [IO.File]::Exists($p) -or (Get-AapZcFileHash $p) -ne $m.sha256) { $binOk = $false }  # SAFETY:WIN-BOOT-BINARY
    }
    if (-not $binOk -or $BudgetBytes -le 0) {
        $cfg.state = 'disabled'
        $cfg.detail = $(if ($binOk) { 'no cache budget' } else { 'installed zccache is not the pinned release' })
    } else {
        $active = @(foreach ($t in @((Read-AapZcJson (Join-Path $InstallDir 'toolchains.json')).toolchains)) {
                if ([IO.File]::Exists($t.path) -and (Get-AapZcFileHash $t.path) -eq $t.sha256) { $t } })  # SAFETY:WIN-BOOT-TOOLCHAIN
        $cfg.toolchains = $active
        $cfg.toolchain_digest = Get-AapZcToolchainDigest $active
        $cfg.qualified = @($w.Platform.qualified | Where-Object { $q = $_; @($active | Where-Object { $_.compiler -eq $q.compiler -and $_.compiler_version -eq $q.compiler_version }).Count })
        $cc = @($cfg.qualified | Where-Object { $_.compiler -ne 'rustc' })
        # ponytail: rustc rows get no RUSTC_WRAPPER here: it needs one executable, and a .cmd launcher mangles
        # arguments; P14 ships a native launcher (INTEGRATION.md, gap G3) before a Windows rustc row is qualified.
        if ($cfg.qualified.Count -and -not $cc.Count) { $cfg.detail = 'only rustc pairs are qualified; RUSTC_WRAPPER needs the native launcher (G3)' }
        elseif ($cc.Count -and -not [IO.File]::Exists($script:LauncherShell)) { $cfg.detail = 'the compiler launcher needs PowerShell 7' }
        elseif ($cc.Count) {
            if (Start-AapZcDaemon ([pscustomobject]$cfg) 'private' $InstallDir) {
                $cfg.state = 'qualified'; $cfg.detail = '{0} qualified pairs' -f $cfg.qualified.Count
                $launcher = '{0};-NoProfile;-NonInteractive;-ExecutionPolicy;Bypass;-File;{1}' -f $script:LauncherShell, (Join-Path $InstallDir 'zcshim.ps1')
                $envLines.Add('AAP_ZC_STATE=' + (Get-AapZcConfigPath $JobRoot))
                $envLines.Add('CMAKE_C_COMPILER_LAUNCHER=' + $launcher); $envLines.Add('CMAKE_CXX_COMPILER_LAUNCHER=' + $launcher)
            } else { $cfg.state = 'degraded'; $cfg.detail = 'daemon did not start; compilers run directly' }
        }
    }
    Write-AapZcJson $cfg (Get-AapZcConfigPath $JobRoot)
    [IO.File]::WriteAllText((Join-Path $JobRoot 'state\runner.env'), (($envLines | ForEach-Object { $_ + "`n" }) -join ''), $script:Utf8)
    return (Read-AapZcJson (Get-AapZcConfigPath $JobRoot))
}

function Connect-AapZcSharedRoot {
    <# Guest agent, when the host binds a shared root (INTEGRATION.md). InstallDir is the cache install; BindingPath is
       the record the agent received over the management transport; MountPath is where the agent mounted the root disk
       the host attached; RunnerName is this VM's name. Nothing is read from the environment. Only a trusted binding is
       ever attached, and only when Initialize-AapZcJob turned shared roots on. Returns
       [pscustomobject]@{ Attached; Reason }; on any refusal the job keeps its private root. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallDir, [Parameter(Mandatory)][string]$JobRoot, [Parameter(Mandatory)][string]$BindingPath,
        [Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)][string]$RunnerName)
    $cfgPath = Get-AapZcConfigPath $JobRoot
    $cfg = Read-AapZcJson $cfgPath
    $reason = $null
    $b = $null
    try { $b = Read-AapZcJson $BindingPath } catch { $b = $null }
    $ns = Get-AapZcProp $b 'namespace'
    $budget = 0L
    try { $budget = [long](Get-AapZcProp $b 'budget_bytes') } catch { $budget = 0L }
    if ((Get-AapZcProp $cfg 'state') -ne 'qualified') { $reason = 'no-qualified-wrappers' }
    elseif ((Get-AapZcProp $cfg 'shared_roots') -ne $true) { $reason = 'shared-roots-off' }  # SAFETY:WIN-BIND-SWITCH
    elseif ($null -ne (Get-AapZcProp $cfg.roots 'shared')) { $reason = 'already-bound' }  # SAFETY:WIN-BIND-ONCE
    elseif ($null -eq $b -or (Get-AapZcProp $b 'schema') -ne 1 -or $null -eq $ns -or [string]::IsNullOrEmpty([string](Get-AapZcProp $b 'root_id')) -or
        @($script:NamespaceKeys | Where-Object { [string]::IsNullOrEmpty([string](Get-AapZcProp $ns $_)) }).Count) { $reason = 'binding-missing' }  # SAFETY:WIN-BIND-MISSING
    elseif ([string](Get-AapZcProp $ns 'trust_class') -cne 'trusted') { $reason = 'not-trusted' }  # SAFETY:WIN-BIND-CLASS
    elseif ([string](Get-AapZcProp $b 'runner_name') -cne $RunnerName) { $reason = 'runner-mismatch' }  # SAFETY:WIN-BIND-RUNNER
    elseif ([string](Get-AapZcProp $ns 'platform') -ne $script:Platform -or [string](Get-AapZcProp $ns 'toolchain_digest') -ne [string](Get-AapZcProp $cfg 'toolchain_digest') -or
        [string](Get-AapZcProp $ns 'zccache_version') -cne [string](Get-AapZcPlatform (Join-Path $InstallDir 'wrappers.json')).Version) { $reason = 'toolchain-mismatch' }  # SAFETY:WIN-BIND-TOOLCHAIN
    elseif ((Test-AapZcLink $MountPath) -or (Test-AapZcLink (Join-Path $MountPath 'root'))) { $reason = 'root-is-link' }  # SAFETY:WIN-BIND-LINK
    elseif ($budget -le 0) { $reason = 'budget-invalid' }
    else {
        $marker = $null
        try { $marker = Read-AapZcJson (Join-Path $MountPath 'aap-cache-root.json') } catch { $marker = $null }
        $mns = Get-AapZcProp $marker 'namespace'
        $same = ($null -ne $mns -and [string](Get-AapZcProp $marker 'root_id') -ceq [string](Get-AapZcProp $b 'root_id'))
        foreach ($k in $script:NamespaceKeys) {
            if ($same -and [string](Get-AapZcProp $mns $k) -cne [string](Get-AapZcProp $ns $k)) { $same = $false }
        }
        if (-not $same) { $reason = 'marker-mismatch' }  # SAFETY:WIN-BIND-MARKER
    }
    if (-not $reason) {
        Set-AapZcProp $cfg.roots 'shared' ([pscustomobject]@{ dir = Join-Path $MountPath 'root'; budget_bytes = $budget
                artifact_budget_bytes = [long][Math]::Floor($budget * 3 / 4); daemon = $null; root_id = [string]$b.root_id; trust_class = 'trusted' })
        if (Start-AapZcDaemon $cfg 'shared' $InstallDir) { $cfg.active_root = 'shared' }
        else { $cfg.roots.PSObject.Properties.Remove('shared'); $reason = 'daemon-start-failed' }
    }
    Set-AapZcProp $cfg 'last_bind' ([ordered]@{ attached = (-not $reason); reason = $reason })
    Write-AapZcJson $cfg $cfgPath
    [pscustomobject]@{ Attached = (-not $reason); Reason = $reason }
}

function Get-AapZcFlagPath($Config, [string]$RootId) { Join-Path $Config.job_root ('shim\degraded-' + $RootId) }

function Get-AapZcState {
    <# For the guest agent's status/collect reply and status.v5.json cache.state: state, detail (printable ASCII,
       at most 200 characters) and byte counts per root, artifacts separate from everything else. #>
    param([Parameter(Mandatory)][string]$JobRoot)
    $cfgPath = Get-AapZcConfigPath $JobRoot
    if (-not [IO.File]::Exists($cfgPath)) { return [pscustomobject]@{ state = 'unknown'; detail = 'cache not initialized'; bytes = $null } }
    $cfg = Read-AapZcJson $cfgPath
    $state = [string]$cfg.state; $detail = [string]$cfg.detail
    $flag = Get-AapZcFlagPath $cfg ([string]$cfg.active_root)
    if ($state -eq 'qualified' -and [IO.File]::Exists($flag)) { $state = 'degraded'; $detail = 'compilers run directly: ' + [IO.File]::ReadAllText($flag).Trim() }
    $bytes = [ordered]@{}
    foreach ($p in $cfg.roots.PSObject.Properties) {
        $all = Measure-AapZcTree $p.Value.dir
        $art = Measure-AapZcTree (Join-Path $p.Value.dir 'artifacts')
        $bytes[$p.Name] = [ordered]@{ artifact = $art; other = $all - $art; budget = [long]$p.Value.budget_bytes }
    }
    $bytes['shim'] = Measure-AapZcTree (Join-Path $JobRoot 'shim')
    $detail = ($detail -replace '[^ -~]', '?')
    if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
    [pscustomobject]@{ state = $state; detail = $detail; bytes = $bytes }
}

# ---- invocation classes (contract enum); $null means "cannot classify", which always builds directly ----

function Expand-AapZcArgs([string[]]$Arguments) {
    $out = New-Object System.Collections.Generic.List[string]
    $rsp = $false
    foreach ($a in $Arguments) {
        if (-not $a.StartsWith('@')) { $out.Add($a); continue }
        $rsp = $true
        $f = $a.Substring(1)
        if (-not [IO.File]::Exists($f)) { return $null }
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f), '"([^"]*)"|(\S+)')) {
            $t = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value })
            if ($t.StartsWith('@')) { return $null }  # nested response files are not classified
            $out.Add($t)
        }
    }
    [pscustomobject]@{ Tokens = $out.ToArray(); ResponseFile = $rsp }
}

function Get-AapZcInvocation {
    param([Parameter(Mandatory)][string]$Compiler, [string[]]$Arguments = @())
    $x = Expand-AapZcArgs $Arguments
    if ($null -eq $x) { return $null }
    $t = @($x.Tokens)
    $classes = New-Object System.Collections.Generic.List[string]
    switch -Exact ($Compiler) {
        'rustc' {
            $types = @()
            for ($i = 0; $i -lt $t.Count; $i++) {
                if ($t[$i] -eq '-' -or $t[$i] -like '--print*' -or $t[$i] -in @('-V', '-vV', '--version')) { return $null }
                if ($t[$i] -eq '--crate-type' -and $i + 1 -lt $t.Count) { $types += $t[$i + 1].Split(',') }
                elseif ($t[$i] -like '--crate-type=*') { $types += $t[$i].Substring(13).Split(',') }
                if ($t[$i] -eq '-g' -or ($t[$i] -match '^-C\s*debuginfo=(.*)$' -and $Matches[1] -notin @('0', 'none')) -or
                    ($t[$i] -eq '-C' -and $i + 1 -lt $t.Count -and $t[$i + 1] -match '^debuginfo=(.*)$' -and $Matches[1] -notin @('0', 'none'))) { $classes.Add('debug-pdb') }
            }
            if (-not $types.Count) { return $null }
            if (@($types | Where-Object { $_ -notin @('lib', 'rlib') }).Count) { $classes.Add('link') } else { $classes.Add('rustc-wrapper') }
        }
        { $_ -in @('clang', 'clang++') } {
            $compile = $false; $pch = $false
            for ($i = 0; $i -lt $t.Count; $i++) {
                $a = $t[$i]
                if ($a -cin @('-', '-E', '-S', '-M', '-MM', '-fsyntax-only', '-###', '--version', '-dumpversion', '-dumpmachine') -or $a -clike '-print-*') { return $null }
                if ($a -ceq '-c') { $compile = $true }
                if (($a -ceq '-x' -and $i + 1 -lt $t.Count -and $t[$i + 1] -like '*-header') -or $a -clike '-x*-header') { $pch = $true }
                if ($a -cin @('-MD', '-MMD', '-MT', '-MQ') -or $a -clike '-MF*') { $classes.Add('depfile') }
                if ($a -clike '-g*' -and $a -cne '-g0' -and $a -notlike '-gno-*') { $classes.Add('debug-pdb') }
            }
            if (-not $compile) { return $null }
            $classes.Add($(if ($pch) { 'compile-pch' } else { 'compile-object' }))
        }
        { $_ -in @('clang-cl', 'cl') } {
            $compile = $false; $pch = $false
            foreach ($a in $t) {
                if ($a.Length -lt 2 -or ($a[0] -ne [char]'/' -and $a[0] -ne [char]'-')) { continue }
                $n = $a.Substring(1)
                if ($n -cin @('E', 'P', 'EP', 'Zs', '?', 'help') -or $n -clike 'Yu*') { return $null }
                if ($n -ceq 'c') { $compile = $true }
                if ($n -clike 'Yc*') { $pch = $true }
                if ($n -cin @('Zi', 'Z7', 'ZI') -or $n -clike 'Fd*') { $classes.Add('debug-pdb') }
                if ($n -cin @('showIncludes', 'sourceDependencies')) { $classes.Add('depfile') }
            }
            if (-not $compile) { return $null }
            $classes.Add($(if ($pch) { 'compile-pch' } else { 'compile-object' }))
        }
        { $_ -in @('link', 'lld-link') } {
            foreach ($a in $t) { if ($a -in @('/lib', '-lib', '/dump', '/edit')) { return $null } }
            $classes.Add('link')
        }
        default { return $null }
    }
    if ($x.ResponseFile) { $classes.Add('response-file') }
    if (@($t + $Arguments | Where-Object { $_ -match ' ' }).Count) { $classes.Add('path-with-spaces') }
    return @($classes | Sort-Object -Unique)
}

# ---- the shim ----

function Write-AapZcLog($Config, [string]$Line) {
    try {
        $log = Join-Path $Config.job_root 'shim\shim.log'
        $fi = New-Object IO.FileInfo($log)
        if ($fi.Exists -and $fi.Length -gt $script:LogLimit) { Move-Item -LiteralPath $log -Destination ($log + '.1') -Force -ErrorAction SilentlyContinue }  # SAFETY:WIN-LOG-BOUND
        $b = $script:Utf8.GetBytes(('{0} {1}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'), $Line) + "`n")
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fs = New-Object IO.FileStream($log, [IO.FileMode]::Append, [IO.FileAccess]::Write, $share)
        try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    } catch { $null = $_ }  # logging never fails a build
}

function Set-AapZcDegraded($Config, [string]$RootId, [string]$Reason) {
    try { [IO.File]::WriteAllText((Get-AapZcFlagPath $Config $RootId), $Reason, $script:Utf8) } catch { $null = $_ }
}

# Measured at most every 30 s per root. Over budget means the root stops being used for this VM; nothing is evicted.
function Test-AapZcOverBudget($Config, [string]$RootId, $Root) {
    $stamp = Join-Path $Config.job_root ('shim\usage-' + $RootId)
    $si = New-Object IO.FileInfo($stamp)
    if ($si.Exists -and ([DateTime]::UtcNow - $si.LastWriteTimeUtc).TotalSeconds -lt $script:UsageEverySeconds) { return $false }
    [IO.File]::WriteAllText($stamp, '')
    $all = Measure-AapZcTree $Root.dir
    $art = Measure-AapZcTree (Join-Path $Root.dir 'artifacts')
    return ($all -gt [long]$Root.budget_bytes -or ($all - $art) -gt ([long]$Root.budget_bytes - [long]$Root.artifact_budget_bytes))  # SAFETY:WIN-OVER-BUDGET
}

function Resolve-AapZcCompiler([string]$Name) {
    if ([IO.Path]::IsPathRooted($Name)) { return [IO.Path]::GetFullPath($Name) }
    $c = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($c.Count) { return $c[0].Source }
    return $null
}

function Get-AapZcDecision([string]$ConfigPath, [string]$Compiler, [string[]]$Arguments) {
    $d = [pscustomobject]@{ Mode = 'direct'; Reason = $null; Path = (Resolve-AapZcCompiler $Compiler); Config = $null; RootId = $null; Root = $null }
    if (-not $ConfigPath -or -not [IO.File]::Exists($ConfigPath)) { $d.Reason = 'no-state'; return $d }
    $cfg = Read-AapZcJson $ConfigPath
    $d.Config = $cfg
    if ($cfg.state -ne 'qualified') { $d.Reason = 'state-' + $cfg.state; return $d }
    $tc = $null
    if ($d.Path) { $tc = @($cfg.toolchains | Where-Object { $_.path -eq $d.Path }) | Select-Object -First 1 }
    if ($null -eq $tc) { $d.Reason = 'unknown-toolchain'; return $d }
    # ponytail: size and mtime per call, the full hash once per boot (Initialize); a hash per call costs more than a compile.
    $fi = New-Object IO.FileInfo($d.Path)
    if (-not $fi.Exists -or $fi.Length -ne [long]$tc.bytes -or $fi.LastWriteTimeUtc.Ticks -ne [long]$tc.mtime) { $d.Reason = 'toolchain-changed'; return $d }  # SAFETY:WIN-SHIM-TOOLCHAIN
    $classes = Get-AapZcInvocation -Compiler $tc.compiler -Arguments $Arguments
    if ($null -eq $classes) { $d.Reason = 'unclassified'; return $d }
    foreach ($c in $classes) {
        $q = @($cfg.qualified | Where-Object { $_.compiler -eq $tc.compiler -and $_.compiler_version -eq $tc.compiler_version -and $_.invocation -eq $c })
        if (-not $q.Count) { $d.Reason = 'not-qualified:' + $c; return $d }  # SAFETY:WIN-SHIM-QUALIFIED
    }
    $d.RootId = [string]$cfg.active_root
    $d.Root = Get-AapZcProp $cfg.roots $d.RootId
    if ([IO.File]::Exists((Get-AapZcFlagPath $cfg $d.RootId))) { $d.Reason = 'degraded'; return $d }  # SAFETY:WIN-SHIM-FLAG
    if (Test-AapZcOverBudget $cfg $d.RootId $d.Root) { Set-AapZcDegraded $cfg $d.RootId 'over-budget'; $d.Reason = 'over-budget'; return $d }
    if (-not (Test-AapZcDaemonAlive $d.Root.daemon)) { Set-AapZcDegraded $cfg $d.RootId 'daemon-down'; $d.Reason = 'daemon-down'; return $d }  # SAFETY:WIN-SHIM-DAEMON
    $d.Mode = 'zccache'
    return $d
}

function Invoke-AapZcShim {
    <# ConfigPath: AAP_ZC_STATE. InstallDir: the folder zcshim.ps1 runs from; zccache is always its bin\ member.
       Argv: the compiler and its arguments exactly as the caller passed them (zcshim.ps1 takes them from the process
       command line, not from PowerShell's parameter parsing). #>
    param([string]$ConfigPath, [string]$InstallDir, [string[]]$Argv)
    if (-not $Argv -or $Argv.Count -lt 1) { [Console]::Error.WriteLine('zcshim: usage: zcshim <compiler> [arguments]'); return 2 }
    $compiler = $Argv[0]
    $rest = @($Argv | Select-Object -Skip 1)
    try { $d = Get-AapZcDecision $ConfigPath $compiler $rest }
    catch { $d = [pscustomobject]@{ Mode = 'direct'; Reason = 'shim-error'; Path = $null; Config = $null; RootId = $null; Root = $null } }
    $exe = $(if ($d.Path) { $d.Path } else { $compiler })
    if ($d.Mode -eq 'zccache') {
        $r = $null
        $timeout = [int](Get-AapZcProp $d.Config 'wrapper_timeout_seconds')
        if ($timeout -le 0) { $timeout = 60 }
        try {
            $r = Invoke-AapZcProcess -FilePath (Get-AapZcBinary $InstallDir) -Arguments (@($exe) + $rest) -Environment (Get-AapZcChildEnv $d.Root) -Capture -TimeoutSeconds $timeout  # SAFETY:WIN-SHIM-TIMEOUT
        } catch { $r = $null }
        if ($null -ne $r -and -not $r.TimedOut -and $r.ExitCode -eq 0) {
            $o = [Console]::OpenStandardOutput(); $o.Write($r.Stdout, 0, $r.Stdout.Length); $o.Flush()
            $e = [Console]::OpenStandardError(); $e.Write($r.Stderr, 0, $r.Stderr.Length); $e.Flush()
            Write-AapZcLog $d.Config ('zccache {0} exit 0' -f [IO.Path]::GetFileName($exe))
            return 0
        }
        # Any zccache failure, a compile error included, is answered by the direct compiler: its exit code and output
        # are the build's (contract rule 7). The wrapped call's output is dropped so errors are not reported twice, and a
        # compile error costs two compiler runs. A call that ran past the bound marks the root degraded either way.
        $code = (Invoke-AapZcProcess -FilePath $exe -Arguments $rest).ExitCode  # SAFETY:WIN-SHIM-FALLBACK
        $timedOut = ($null -ne $r -and $r.TimedOut)
        if ($timedOut) { Set-AapZcDegraded $d.Config $d.RootId 'wrapper-timeout' }
        elseif ($code -eq 0) { Set-AapZcDegraded $d.Config $d.RootId 'wrapper-failure' }
        Write-AapZcLog $d.Config ('fallback {0} zccache-exit {1} direct-exit {2}' -f [IO.Path]::GetFileName($exe), $(if ($timedOut) { 'timeout' } elseif ($r) { $r.ExitCode } else { 'none' }), $code)
        return $code
    }
    try { $code = (Invoke-AapZcProcess -FilePath $exe -Arguments $rest).ExitCode }
    catch { [Console]::Error.WriteLine("zcshim: cannot run $compiler"); $code = 127 }
    if ($d.Config) { Write-AapZcLog $d.Config ('direct {0} {1} exit {2}' -f [IO.Path]::GetFileName($exe), $d.Reason, $code) }
    return $code
}

Export-ModuleMember -Function Install-AapZcCache, Initialize-AapZcJob, Connect-AapZcSharedRoot, Get-AapZcState, Invoke-AapZcShim,
    Get-AapZcInvocation, Get-AapZcToolchainDigest, Get-AapZcChildEnv, ConvertTo-AapZcArg
