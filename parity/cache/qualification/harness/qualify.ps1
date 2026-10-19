# zccache 1.15.6 qualification harness, Windows x86_64. LAB ONLY (P13/P22), see ../README.md.
#
# Runs one (compiler, invocation) pair through method steps 1-6: uncached, cold and warm builds,
# a relocated build for debug-pdb, two poisoned-cache builds and the deliberate-error case. Every
# case uses its own fresh cache root. It compares exit codes and artifact hashes, counts journal
# outcomes and writes one evidence record via record.jq. It never emits "qualified": the record's
# row stays "direct" and `harness_pass` says whether steps 1-6 held. Lab steps 7-9 decide the rest.
# zccache runs from a private, hash-checked copy under -Work; its daemons are stopped at the end.
#
# Exit codes: 0 record written (read harness_pass), 1 unexpected harness error (no record),
# 2 usage, 3 refused (not a clean lab), 4 zccache.exe or zccache-fp.exe is not the pinned binary.
#
# Windows PowerShell 5.1 and PowerShell 7. Needs jq on PATH. Run from a Developer PowerShell for
# cl/link, in a clean session: no tokens, keys or runner JIT config in the environment.
[CmdletBinding()]
param(
    [string]$Compiler,          # matrix compiler name, e.g. clang-cl
    [string]$CompilerPath,      # the real compiler executable
    [string]$CompilerVersion,   # exactly the matrix row's compiler_version
    [string]$Invocation,        # matrix invocation class
    [string]$Zccache,           # unpacked zccache.exe from the pinned archive (zccache-fp.exe beside it)
    [string]$Out,               # where the evidence JSON is written
    [string]$EvidenceRef,       # repo path the reviewer will commit the record under
    [string]$PrereqCompiler,    # link/lld-link only: cl.exe or clang-cl.exe that builds the objects
    [string]$Work,              # empty scratch directory, not a link or junction
    [string[]]$ExtraMarkerRoot  # tests only: more roots to probe for live-install markers
)

$ZqBinarySha256 = '41de068f3024a1bcbfea8ad488455c648ee07903e09e9fca4d663436789d0731'
$ZqFpSha256 = '4c0892e47244fdc38a6542ed3b05d2d9f26d312bce505984e6a9f6766c66c987'
$ZqPairs = @{
    'rustc'    = @('rustc-wrapper', 'link', 'path-with-spaces', 'debug-pdb')
    'clang'    = @('compile-object', 'compile-pch', 'response-file', 'depfile', 'path-with-spaces')
    'clang++'  = @('compile-object', 'compile-pch', 'response-file', 'depfile', 'path-with-spaces')
    'clang-cl' = @('compile-object', 'response-file', 'debug-pdb', 'path-with-spaces')
    'cl'       = @('compile-object', 'compile-pch', 'response-file', 'debug-pdb')
    'link'     = @('link')
    'lld-link' = @('link')
}
$ZqEvidencePattern = '^parity/cache/qualification/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
# Variable names that look like credentials (the zccache daemon and its crash dumps inherit them).
$ZqSecretName = '(?i)token|secret|passw|credential|jit|private_?key|(^|_)(api_?)?key$|pem$'
$ZqHere = $PSScriptRoot

function Get-ZqMarkerPath([string[]]$Roots) {
    # The live pool on the owner's host: installer, supervisor data and the WSL distro root.
    # ProgramW6432 matters when a 32-bit PowerShell resolves ProgramFiles to Program Files (x86).
    $paths = @("$env:ProgramData\aap-runner", "$env:ProgramFiles\aap-runner", "$env:SystemDrive\wsl")
    if ($env:ProgramW6432) { $paths += "$env:ProgramW6432\aap-runner" }
    foreach ($r in $Roots) {
        if ($r) { $paths += @('ProgramData\aap-runner', 'Program Files\aap-runner', 'wsl' | ForEach-Object { [IO.Path]::Combine($r, $_) }) }
    }
    $paths
}

function Find-ZqSecretEnv([string[]]$Names) { @($Names | Where-Object { $_ -match $ZqSecretName } | Sort-Object -Unique) }

function Assert-ZqLab([string[]]$Candidates, [string[]]$EnvNames) {
    if ($env:AAP_ZCCACHE_LAB -ne '1') {
        throw 'REFUSED: AAP_ZCCACHE_LAB=1 is not set; this harness runs only inside a disposable lab VM'
    }
    $found = @($Candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($found.Count -gt 0) {
        throw "REFUSED: live aap-runner install markers present: $($found -join ', ')"
    }
    $secret = Find-ZqSecretEnv $EnvNames
    if ($secret.Count -gt 0) {
        throw "REFUSED: credential-shaped environment variables present (names only): $($secret -join ', '); start the harness from a clean session"
    }
}

function Test-ZqArg {
    param($Compiler, $CompilerPath, $CompilerVersion, $Invocation, $Zccache, $Out, $EvidenceRef, $PrereqCompiler, $Work)
    if (-not $ZqPairs.ContainsKey([string]$Compiler)) { throw "USAGE: compiler '$Compiler' is not one of $($ZqPairs.Keys -join ', ')" }
    if ($ZqPairs[$Compiler] -notcontains $Invocation) { throw "USAGE: $Compiler has no '$Invocation' row in the Windows matrix" }
    if (-not $CompilerVersion) { throw 'USAGE: -CompilerVersion must equal the matrix row' }
    if ($EvidenceRef -notmatch $ZqEvidencePattern -or $EvidenceRef -match '(^|/)\.\.?(/|$)') { throw "USAGE: -EvidenceRef '$EvidenceRef' is not under parity/cache/qualification/" }
    if (-not $Out) { throw 'USAGE: -Out is required' }
    foreach ($p in @($CompilerPath, $Zccache)) { if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "USAGE: '$p' is not a file" } }
    if ($Compiler -in @('link', 'lld-link') -and (-not $PrereqCompiler -or -not (Test-Path -LiteralPath $PrereqCompiler -PathType Leaf))) { throw 'USAGE: link rows need -PrereqCompiler' }
    if (-not $Work) { throw 'USAGE: -Work is required' }
    if (Test-Path -LiteralPath $Work) {
        $item = Get-Item -LiteralPath $Work -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'USAGE: -Work must not be a symbolic link or junction' }
        if (-not $item.PSIsContainer -or @(Get-ChildItem -LiteralPath $Work -Force).Count -gt 0) { throw 'USAGE: -Work must name an empty or new directory' }
    }
}

# Non-MSVC compilers must name the matrix version in their --version banner. cl and link print
# a 19.xx toolset banner that the matrix version string does not carry (README "Rows").
function Test-ZqBanner([string]$Compiler, [string]$Version, [string]$Banner) {
    if ($Compiler -in @('cl', 'link')) { return }
    if ($Version -notmatch '^\d+(\.\d+)+$') { throw "USAGE: -CompilerVersion '$Version' must be dotted digits for $Compiler" }
    if ($Banner -notmatch ('(?<![\d.])' + [regex]::Escape($Version) + '(?!\.?\d)')) {
        $first = @($Banner -split "`r?`n" | Where-Object { $_.Trim() })[0]
        throw "USAGE: the $Compiler banner does not name version ${Version}: $first"
    }
}

# Argument list and primary artifact for one run in $Src (outputs in $Src\out). $Case is 'ok' or
# 'error'. Runs execute with the working directory at $Src; debug-pdb uses relative paths so the
# relocated build exercises the working-directory (comp_dir) hazard.
function Get-ZqCommand([string]$Compiler, [string]$Invocation, [string]$Src, [string]$Case, [string]$Rsp, [string]$Pre) {
    $bad = $Case -eq 'error'
    $rel = $Invocation -eq 'debug-pdb'
    $S = if ($rel) { '' } else { $Src.TrimEnd('\') + '\' }
    $O = if ($rel) { 'out\' } else { $Src.TrimEnd('\') + '\out\' }
    $c = if ($bad) { 'error.c' } else { 'hello.c' }
    if ($Compiler -eq 'clang++') { $c = if ($bad) { 'error.cpp' } else { 'hello.cpp' } }
    $source = $S + $c
    switch -Regex ($Compiler) {
        '^rustc$' {
            # Binary crates pass through uncached upstream (README 400-403); only libraries cache.
            if ($Invocation -in @('rustc-wrapper', 'path-with-spaces')) {
                $lib = $S + $(if ($bad) { 'error.rs' } else { 'lib.rs' })
                return @{ Args = @('--crate-name', 'hello', '--edition', '2021', '--crate-type', 'lib', '--emit=metadata,link', $lib, '--out-dir', $O.TrimEnd('\')); Primary = 'libhello.rlib' }
            }
            $rs = $S + $(if ($bad) { 'error.rs' } else { 'hello.rs' })
            if ($Invocation -eq 'debug-pdb') { return @{ Args = @('-C', 'debuginfo=2', $rs, '-o', ($O + 'hello.exe')); Primary = 'hello.exe' } }
            return @{ Args = @($rs, '-o', ($O + 'hello.exe')); Primary = 'hello.exe' }
        }
        '^clang(\+\+)?$' {
            $o = $O + 'hello.o'
            switch ($Invocation) {
                'compile-pch' {
                    $lang = if ($Compiler -eq 'clang++') { 'c++-header' } else { 'c-header' }
                    $h = if ($bad) { $source } else { $S + 'hello.h' }
                    return @{ Args = @('-x', $lang, $h, '-o', ($O + 'hello.h.pch')); Primary = 'hello.h.pch' }
                }
                'response-file' {
                    # Forward slashes: GNU-style response-file quoting treats backslash as an escape.
                    $line = (@('-c', $source, '-o', $o) | ForEach-Object { '"' + ($_ -replace '\\', '/') + '"' }) -join ' '
                    [IO.File]::WriteAllText($Rsp, $line)
                    return @{ Args = @("@$Rsp"); Primary = 'hello.o' }
                }
                'depfile' { return @{ Args = @('-c', $source, '-o', $o, '-MD', '-MF', ($O + 'hello.d')); Primary = 'hello.o' } }
                default { return @{ Args = @('-c', $source, '-o', $o); Primary = 'hello.o' } }
            }
        }
        '^(clang-cl|cl)$' {
            $fo = '/Fo' + $O + 'hello.obj'
            switch ($Invocation) {
                'compile-pch' { return @{ Args = @('/nologo', '/c', '/Brepro', '/Ychello.h', $source, ('/Fp' + $O + 'hello.pch'), $fo); Primary = 'hello.pch' } }
                'debug-pdb' { return @{ Args = @('/nologo', '/c', '/Brepro', '/Zi', $source, $fo, ('/Fd' + $O + 'hello.pdb')); Primary = 'hello.obj' } }
                'response-file' {
                    [IO.File]::WriteAllText($Rsp, ((@('/nologo', '/c', '/Brepro', $source, $fo) | ForEach-Object { '"' + $_ + '"' }) -join ' '))
                    return @{ Args = @("@$Rsp"); Primary = 'hello.obj' }
                }
                default { return @{ Args = @('/nologo', '/c', '/Brepro', $source, $fo); Primary = 'hello.obj' } }
            }
        }
        '^(link|lld-link)$' {
            $obj = Join-Path $Pre $(if ($bad) { 'unresolved.obj' } else { 'hello.obj' })
            return @{ Args = @('/nologo', '/Brepro', $obj, ('/OUT:' + $O + 'hello.exe')); Primary = 'hello.exe' }
        }
    }
    throw "USAGE: no command for $Compiler/$Invocation"
}

function Get-ZqSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# Printable ASCII, at most 120 characters (evidence-bundle tool_versions values).
function Get-ZqPrintable([string]$Text) {
    $t = ([string]$Text -replace '[^\x20-\x7E]', '?').Trim()
    $t.Substring(0, [Math]::Min(120, $t.Length))
}

# Regular files below $Dir. Symbolic links and junctions are never followed (Windows PowerShell 5.1
# recursion would descend into directory links), and a linked $Dir yields nothing.
function Get-ZqFiles([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return }
    if ((Get-Item -LiteralPath $Dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
    foreach ($i in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($i.PSIsContainer) { Get-ZqFiles $i.FullName } else { $i }
    }
}

function Get-ZqArtifact([string]$Dir) {
    $h = [ordered]@{}
    Get-ZqFiles $Dir | Sort-Object FullName | ForEach-Object {
        $h[$_.FullName.Substring($Dir.Length).TrimStart('\')] = Get-ZqSha256 $_.FullName
    }
    $h
}

function Invoke-ZqJq([string]$Jq, [string[]]$Argv) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Jq @Argv) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "jq failed ($LASTEXITCODE): $($Argv -join ' ')" }
        $text
    } finally { $ErrorActionPreference = $prev }
}

# Outcome counts from a per-session journal (journal.jq), or $null when there is no journal.
function Get-ZqJournal([string]$Journal, [string]$Jq) {
    if (-not (Test-Path -LiteralPath $Journal -PathType Leaf)) { return $null }
    Invoke-ZqJq $Jq @('-R', '-s', '-c', '-f', (Join-Path $ZqHere 'journal.jq'), $Journal) | ConvertFrom-Json
}

# The evidence record (record.jq) for {meta, runs, errors}; returns the JSON text.
function New-ZqRecord($InputObject, [string]$Jq, [string]$Scratch) {
    $in = Join-Path $Scratch ('record-input-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($in, ($InputObject | ConvertTo-Json -Depth 12))
    try { Invoke-ZqJq $Jq @('-a', '-f', (Join-Path $ZqHere 'record.jq'), $in) } finally { Remove-Item -LiteralPath $in -ErrorAction SilentlyContinue }
}

# Always an array, also with zero or one name (the leading comma stops PowerShell unrolling it).
function Get-ZqZccacheEnvName { , @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ZCCACHE_*' } | ForEach-Object { $_.Name } | Sort-Object) }

# Removes every ZCCACHE_* variable so nothing leaks from the lab shell; returns the removed names.
function Clear-ZqEnv {
    $names = Get-ZqZccacheEnvName
    foreach ($n in $names) { Remove-Item -LiteralPath "Env:\$n" }
    , $names
}

# Corrupts every regular file in a cache store (links are not followed); returns how many changed.
# -SameSize flips one byte mid-file in place, keeping length and modification time, so only a
# content check can notice (upstream does not claim to prove integrity, README 1123). Otherwise
# the file becomes the 10-byte marker P04-POISON, which changes its length.
function Invoke-ZqCorrupt([string]$Store, [switch]$SameSize) {
    $n = 0
    foreach ($f in @(Get-ZqFiles $Store)) {
        if ($SameSize -and $f.Length -eq 0) { continue }
        $ro = $f.IsReadOnly; $mtime = $f.LastWriteTimeUtc
        try {
            if ($ro) { $f.IsReadOnly = $false }
            if ($SameSize) {
                $at = [long][Math]::Floor($f.Length / 2)
                $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                try {
                    $fs.Position = $at; $b = $fs.ReadByte()
                    $fs.Position = $at; $fs.WriteByte([byte]($b -bxor 0xFF))
                } finally { $fs.Dispose() }
                [IO.File]::SetLastWriteTimeUtc($f.FullName, $mtime)
            } else {
                [IO.File]::WriteAllBytes($f.FullName, [Text.Encoding]::ASCII.GetBytes('P04-POISON'))
            }
            $n++
        } catch {
            continue  # a locked entry stays uncounted; zero corrupted files fails the check
        } finally {
            if ($ro) { $f.Refresh(); $f.IsReadOnly = $true }
        }
    }
    $n
}

function Get-ZqOwnProcess([string]$Bin) {
    $prefix = $Bin.TrimEnd('\') + '\'
    @(Get-Process -Name 'zccache*' -ErrorAction SilentlyContinue | Where-Object {
            $p = $null; try { $p = $_.Path } catch { }
            $p -and $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
}

# Every visible zccache* process: the lab records which binary the daemons really run.
function Get-ZqDaemon([string]$Bin) {
    $prefix = $Bin.TrimEnd('\') + '\'
    , @(Get-Process -Name 'zccache*' -ErrorAction SilentlyContinue | ForEach-Object {
            $p = $null; try { $p = $_.Path } catch { }
            [ordered]@{
                pid = $_.Id
                exe = $(if ($p) { Get-ZqPrintable $p } else { $null })
                in_private_bin = [bool]($p -and $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
                sha256 = $(if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { Get-ZqSha256 $p } else { $null })
            }
        })
}

# Stops every process running from the private copy; $true when none is left.
function Stop-ZqDaemon([string]$Bin) {
    foreach ($p in (Get-ZqOwnProcess $Bin)) { try { $p.Kill(); $null = $p.WaitForExit(5000) } catch { } }
    (Get-ZqOwnProcess $Bin).Count -eq 0
}

# Files under each cache root's crashes/ folder. The dumps themselves never leave the VM.
function Get-ZqCrashDump([string]$Work) {
    $counts = [ordered]@{}
    foreach ($d in @(Get-ChildItem -LiteralPath $Work -Directory -Filter 'cache-*' -ErrorAction SilentlyContinue)) {
        $counts[$d.Name] = @(Get-ZqFiles (Join-Path $d.FullName 'crashes')).Count
    }
    $counts
}

function Get-ZqOs {
    $os = $null; $ubr = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $ubr = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction Stop).UBR } catch { }
    $v = if ($os) { "$($os.Caption) $($os.Version)" + $(if ($null -ne $ubr) { ".$ubr" } else { '' }) } else { [Environment]::OSVersion.VersionString }
    [ordered]@{
        os_version = Get-ZqPrintable $v
        image_os = $(if ($env:ImageOS) { Get-ZqPrintable $env:ImageOS } else { $null })
        image_version = $(if ($env:ImageVersion) { Get-ZqPrintable $env:ImageVersion } else { $null })
    }
}

function Invoke-ZqRun([string]$Exe, [string[]]$Argv, [string]$Log, [string]$Cwd) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $Cwd
    try { & $Exe @Argv > "$Log.out" 2> "$Log.err"; $LASTEXITCODE } finally { Pop-Location; $ErrorActionPreference = $prev }
}

# One build. $Root empty: the compiler directly. Otherwise through zccache with that cache root,
# inside a journaled session.
function Invoke-ZqPhase($Ctx, [string]$Src, [string]$Case, [string]$Root, [string]$Name) {
    $outDir = Join-Path $Src 'out'
    if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction Stop }
    $null = New-Item -ItemType Directory -Path $outDir -ErrorAction Stop
    $cmd = Get-ZqCommand $Ctx.Compiler $Ctx.Invocation $Src $Case $Ctx.Rsp $Ctx.Pre
    $log = Join-Path $Ctx.Logs $Name
    $journal = $null
    if (-not $Root) {
        $zenv = Get-ZqZccacheEnvName
        $rc = Invoke-ZqRun $Ctx.Cc $cmd.Args $log $Src
    } else {
        $env:ZCCACHE_CACHE_DIR = $Root
        $sid = $null
        try {
            $null = Invoke-ZqRun $Ctx.Zc @('session-start', '--journal', "$log.jsonl") "$log.session-start" $Src
            $sid = [string]((Get-Content -Raw -LiteralPath "$log.session-start.out") | ConvertFrom-Json).session_id
        } catch { $sid = $null }
        if ($sid) { $env:ZCCACHE_SESSION_ID = $sid }
        $zenv = Get-ZqZccacheEnvName
        try {
            $rc = Invoke-ZqRun $Ctx.Zc (@($Ctx.Cc) + $cmd.Args) $log $Src
        } finally {
            if ($sid) { $null = Invoke-ZqRun $Ctx.Zc @('session-end', $sid, '--json') "$log.session-end" $Src }
            Remove-Item Env:\ZCCACHE_SESSION_ID, Env:\ZCCACHE_CACHE_DIR -ErrorAction SilentlyContinue
        }
        if ($sid) { $journal = Get-ZqJournal "$log.jsonl" $Ctx.Jq }
    }
    [ordered]@{
        exit = $rc; artifacts = (Get-ZqArtifact $outDir); primary_present = (Test-Path -LiteralPath (Join-Path $outDir $cmd.Primary))
        argv = @($cmd.Args); cache_dir = $(if ($Root) { Split-Path -Leaf $Root } else { $null }); zccache_env = $zenv; journal = $journal
    }
}

function New-ZqTree([string]$Work, [string]$Name) {
    $d = Join-Path $Work $Name
    $null = New-Item -ItemType Directory -Path $d -ErrorAction Stop
    Copy-Item -Path (Join-Path $ZqHere 'fixtures\*') -Destination $d -ErrorAction Stop
    $d
}

function Invoke-ZqMain {
    Assert-ZqLab (Get-ZqMarkerPath $ExtraMarkerRoot) @(Get-ChildItem Env: | ForEach-Object { $_.Name })
    $removed = Clear-ZqEnv
    Test-ZqArg -Compiler $Compiler -CompilerPath $CompilerPath -CompilerVersion $CompilerVersion -Invocation $Invocation `
        -Zccache $Zccache -Out $Out -EvidenceRef $EvidenceRef -PrereqCompiler $PrereqCompiler -Work $Work
    $jq = @(Get-Command jq -CommandType Application -ErrorAction SilentlyContinue)[0].Source
    if (-not $jq) { throw 'USAGE: jq is not on PATH' }
    # Absolute paths before any run changes the working directory.
    $cc = (Resolve-Path -LiteralPath $CompilerPath).ProviderPath
    $zcSource = (Resolve-Path -LiteralPath $Zccache).ProviderPath
    $fpSource = Join-Path (Split-Path -Parent $zcSource) 'zccache-fp.exe'
    $pre = if ($PrereqCompiler) { (Resolve-Path -LiteralPath $PrereqCompiler).ProviderPath } else { $null }
    $outFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
    if (-not (Test-Path -LiteralPath $fpSource -PathType Leaf)) { throw "BINARY: $fpSource is missing; unpack zccache-fp.exe beside zccache.exe" }

    # Run a private copy under -Work, hashed after copying, never the file given on the command line.
    $null = New-Item -ItemType Directory -Force -Path $Work
    $w = (Resolve-Path -LiteralPath $Work).ProviderPath
    $logs = Join-Path $w 'logs'
    $bin = Join-Path $w 'bin'
    $null = New-Item -ItemType Directory -Path $logs, $bin
    Copy-Item -LiteralPath $zcSource -Destination (Join-Path $bin 'zccache.exe') -ErrorAction Stop
    Copy-Item -LiteralPath $fpSource -Destination (Join-Path $bin 'zccache-fp.exe') -ErrorAction Stop
    $zc = Join-Path $bin 'zccache.exe'
    $zsha = Get-ZqSha256 $zc
    $fpsha = Get-ZqSha256 (Join-Path $bin 'zccache-fp.exe')
    if ($zsha -ne $ZqBinarySha256) { throw "BINARY: $zcSource is $zsha, not the pinned 1.15.6 zccache.exe" }
    if ($fpsha -ne $ZqFpSha256) { throw "BINARY: $fpSource is $fpsha, not the pinned 1.15.6 zccache-fp.exe" }

    try {
        $env:ZCCACHE_MODE = 'COPY'   # contract rule 6; hardlink and reflink need their own proof
        $started = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $null = Invoke-ZqRun $cc @('--version') (Join-Path $logs 'compiler-version') $w   # cl prints its banner to stderr
        $banner = (@(Get-Content -LiteralPath (Join-Path $logs 'compiler-version.out'), (Join-Path $logs 'compiler-version.err') -ErrorAction SilentlyContinue) -join "`n")
        Test-ZqBanner $Compiler $CompilerVersion $banner
        $null = Invoke-ZqRun $zc @('--version') (Join-Path $logs 'zccache-version') $w
        $zver = @(Get-Content -LiteralPath (Join-Path $logs 'zccache-version.out') -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })[0]

        $src = New-ZqTree $w $(if ($Invocation -eq 'path-with-spaces') { 'src with spaces' } else { 'src' })
        $preDir = $null
        $tools = [ordered]@{
            compiler = (Get-ZqPrintable (@($banner -split "`n" | Where-Object { $_.Trim() })[0])); compiler_path = (Get-ZqPrintable $cc); compiler_sha256 = (Get-ZqSha256 $cc)
            zccache = (Get-ZqPrintable $zver); zccache_sha256 = $zsha; 'zccache-fp_sha256' = $fpsha
        }
        if ($Compiler -in @('link', 'lld-link')) {
            $preDir = Join-Path $w 'pre'
            $null = New-Item -ItemType Directory -Path $preDir
            foreach ($n in @('hello', 'unresolved')) {
                $rc = Invoke-ZqRun $pre @('/nologo', '/c', '/Brepro', (Join-Path $src "$n.c"), ('/Fo' + (Join-Path $preDir "$n.obj"))) (Join-Path $logs "pre-$n") $w
                if ($rc -ne 0) { throw "USAGE: prerequisite compile of $n.c failed ($rc)" }
            }
            $tools.prereq_compiler_path = Get-ZqPrintable $pre
            $tools.prereq_compiler_sha256 = Get-ZqSha256 $pre
        }
        $ctx = @{ Compiler = $Compiler; Invocation = $Invocation; Cc = $cc; Zc = $zc; Jq = $jq; Rsp = (Join-Path $w 'args.rsp'); Pre = $preDir; Logs = $logs }

        # Fresh cache root per case; no cache root is ever deleted (its daemon may still be alive).
        $runs = [ordered]@{}
        $runs.uncached = Invoke-ZqPhase $ctx $src 'ok' '' 'ok-uncached'
        $runs.cold = Invoke-ZqPhase $ctx $src 'ok' (Join-Path $w 'cache-ok') 'ok-cold'
        $runs.warm = Invoke-ZqPhase $ctx $src 'ok' (Join-Path $w 'cache-ok') 'ok-warm'
        if ($Invocation -eq 'debug-pdb') {
            $moved = New-ZqTree $w 'relocated'
            $runs.relocated_direct = Invoke-ZqPhase $ctx $moved 'ok' '' 'ok-relocated-direct'
            $runs.relocated = Invoke-ZqPhase $ctx $moved 'ok' (Join-Path $w 'cache-ok') 'ok-relocated'
        }
        foreach ($v in @('same_size', 'marker')) {
            $root = Join-Path $w ('cache-poison-' + $v.Replace('_', '-'))
            $prime = Invoke-ZqPhase $ctx $src 'ok' $root "ok-prime-$v"
            $n = Invoke-ZqCorrupt (Join-Path $root 'artifacts') -SameSize:($v -eq 'same_size')
            $p = Invoke-ZqPhase $ctx $src 'ok' $root "ok-poisoned-$v"
            $p.prime_exit = $prime.exit
            $p.corrupted_files = $n
            $runs["poisoned_$v"] = $p
        }
        $errs = [ordered]@{}
        $errs.uncached = Invoke-ZqPhase $ctx $src 'error' '' 'error-uncached'
        $errs.cold = Invoke-ZqPhase $ctx $src 'error' (Join-Path $w 'cache-error') 'error-cold'
        $errs.warm = Invoke-ZqPhase $ctx $src 'error' (Join-Path $w 'cache-error') 'error-warm'

        $daemons = Get-ZqDaemon $bin
        $crashes = Get-ZqCrashDump $w
        $stopped = Stop-ZqDaemon $bin
        $meta = [ordered]@{
            platform = 'windows-x86_64'
            command = "qualify.ps1 -Compiler $Compiler -CompilerVersion '$CompilerVersion' -Invocation $Invocation -EvidenceRef $EvidenceRef"
            tool_versions = $tools
            os = Get-ZqOs
            env = [ordered]@{
                set = [ordered]@{ ZCCACHE_MODE = 'COPY'; ZCCACHE_CACHE_DIR = '<work>\<cache_dir> per wrapped run'; ZCCACHE_SESSION_ID = 'per wrapped run, from session-start' }
                removed = $removed
            }
            daemons = $daemons; daemons_stopped = $stopped; crash_dumps = $crashes
            started_at = $started; ended_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            compiler = $Compiler; compiler_version = $CompilerVersion; invocation = $Invocation; evidence_ref = $EvidenceRef
        }
        $record = New-ZqRecord ([ordered]@{ meta = $meta; runs = $runs; errors = $errs }) $jq $w
        [IO.File]::WriteAllText($outFile, $record + "`n")
        $r = $record | ConvertFrom-Json
        Write-Output "harness_pass=$($r.harness_pass): $($r.row.reason)"
    } finally {
        $null = Stop-ZqDaemon $bin   # also after a failure; crash dumps stay in the VM
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    Invoke-ZqMain
    exit 0
} catch {
    $m = $_.Exception.Message
    [Console]::Error.WriteLine($m)
    if ($m -like 'REFUSED:*') { exit 3 }
    if ($m -like 'BINARY:*') { exit 4 }
    if ($m -like 'USAGE:*') { exit 2 }
    exit 1
}
