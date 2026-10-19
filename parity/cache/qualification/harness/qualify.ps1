# zccache 1.15.6 qualification harness, Windows x86_64. LAB ONLY (P13/P22), see ../README.md.
#
# Runs one (compiler, invocation) pair through method steps 1-6: uncached, cold and warm builds,
# a relocated build for debug-pdb, two poisoned-cache builds and the deliberate-error case. Every
# case uses its own fresh cache root. It compares exit codes and artifact hashes, counts journal
# outcomes and writes one evidence record via record.jq. It never emits "qualified": the record's
# row stays "direct" and `harness_pass` says whether steps 1-6 held. Lab steps 7-9 decide the rest.
#
# Exit codes: 0 record written (read harness_pass), 1 unexpected harness error (no record),
# 2 usage, 3 refused (not a lab), 4 zccache.exe or zccache-fp.exe is not the pinned release binary.
#
# Windows PowerShell 5.1 and PowerShell 7. Needs jq on PATH. Run from a Developer PowerShell for cl/link.
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
    [string]$Work,              # empty scratch directory
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
$ZqHere = $PSScriptRoot

function Get-ZqMarkerPath([string[]]$Roots) {
    # The live pool on the owner's host: installer, supervisor data and the WSL distro root.
    $paths = @("$env:ProgramData\aap-runner", "$env:ProgramFiles\aap-runner", "$env:SystemDrive\wsl")
    foreach ($r in $Roots) {
        if ($r) { $paths += @('ProgramData\aap-runner', 'Program Files\aap-runner', 'wsl' | ForEach-Object { [IO.Path]::Combine($r, $_) }) }
    }
    $paths
}

function Assert-ZqLab([string[]]$Candidates) {
    if ($env:AAP_ZCCACHE_LAB -ne '1') {
        throw 'REFUSED: AAP_ZCCACHE_LAB=1 is not set; this harness runs only inside a disposable lab VM'
    }
    $found = @($Candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($found.Count -gt 0) {
        throw "REFUSED: live aap-runner install markers present: $($found -join ', ')"
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
    if (-not $Work -or ((Test-Path -LiteralPath $Work) -and @(Get-ChildItem -LiteralPath $Work -Force).Count -gt 0)) { throw 'USAGE: -Work must name an empty or new directory' }
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

function Get-ZqArtifact([string]$Dir) {
    $h = [ordered]@{}
    Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
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

# Removes every ZCCACHE_* variable so nothing leaks from the lab shell; returns the removed names.
function Clear-ZqEnv {
    $names = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ZCCACHE_*' } | ForEach-Object { $_.Name } | Sort-Object)
    foreach ($n in $names) { Remove-Item -LiteralPath "Env:\$n" }
    , $names
}

# Corrupts every file in a cache store; returns how many changed. -SameSize keeps each file's size
# and modification time (every byte + 1), so only a content check can notice; otherwise the file
# becomes the short marker P04-POISON.
function Invoke-ZqCorrupt([string]$Store, [switch]$SameSize) {
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Store -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($SameSize -and $f.Length -eq 0) { continue }
        $ro = $f.IsReadOnly; $mtime = $f.LastWriteTimeUtc
        try {
            if ($ro) { $f.IsReadOnly = $false }
            if ($SameSize) {
                $b = [IO.File]::ReadAllBytes($f.FullName)
                for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [byte](($b[$i] + 1) -band 0xFF) }
                [IO.File]::WriteAllBytes($f.FullName, $b)
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
        $rc = Invoke-ZqRun $Ctx.Cc $cmd.Args $log $Src
    } else {
        $env:ZCCACHE_CACHE_DIR = $Root
        $sid = $null
        try {
            $null = Invoke-ZqRun $Ctx.Zc @('session-start', '--journal', "$log.jsonl") "$log.session-start" $Src
            $sid = [string]((Get-Content -Raw -LiteralPath "$log.session-start.out") | ConvertFrom-Json).session_id
        } catch { $sid = $null }
        if ($sid) { $env:ZCCACHE_SESSION_ID = $sid }
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
        argv = @($cmd.Args); cache_dir = $(if ($Root) { Split-Path -Leaf $Root } else { $null }); journal = $journal
    }
}

function New-ZqTree([string]$Work, [string]$Name) {
    $d = Join-Path $Work $Name
    $null = New-Item -ItemType Directory -Path $d -ErrorAction Stop
    Copy-Item -Path (Join-Path $ZqHere 'fixtures\*') -Destination $d -ErrorAction Stop
    $d
}

function Invoke-ZqMain {
    Assert-ZqLab (Get-ZqMarkerPath $ExtraMarkerRoot)
    Test-ZqArg -Compiler $Compiler -CompilerPath $CompilerPath -CompilerVersion $CompilerVersion -Invocation $Invocation `
        -Zccache $Zccache -Out $Out -EvidenceRef $EvidenceRef -PrereqCompiler $PrereqCompiler -Work $Work
    $jq = @(Get-Command jq -CommandType Application -ErrorAction SilentlyContinue)[0].Source
    if (-not $jq) { throw 'USAGE: jq is not on PATH' }
    # Absolute paths before any run changes the working directory.
    $cc = (Resolve-Path -LiteralPath $CompilerPath).ProviderPath
    $zc = (Resolve-Path -LiteralPath $Zccache).ProviderPath
    $pre = if ($PrereqCompiler) { (Resolve-Path -LiteralPath $PrereqCompiler).ProviderPath } else { $null }
    $outFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
    $zsha = Get-ZqSha256 $zc
    if ($zsha -ne $ZqBinarySha256) { throw "BINARY: $zc is $zsha, not the pinned 1.15.6 zccache.exe" }
    $fp = Join-Path (Split-Path -Parent $zc) 'zccache-fp.exe'
    $fpsha = if (Test-Path -LiteralPath $fp -PathType Leaf) { Get-ZqSha256 $fp } else { 'missing' }
    if ($fpsha -ne $ZqFpSha256) { throw "BINARY: $fp is $fpsha, not the pinned 1.15.6 zccache-fp.exe" }

    $removed = Clear-ZqEnv
    $env:ZCCACHE_MODE = 'COPY'   # contract rule 6; hardlink and reflink need their own proof
    $started = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $null = New-Item -ItemType Directory -Force -Path $Work
    $w = (Resolve-Path -LiteralPath $Work).ProviderPath
    $logs = Join-Path $w 'logs'
    $null = New-Item -ItemType Directory -Path $logs
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

    $meta = [ordered]@{
        platform = 'windows-x86_64'
        command = "qualify.ps1 -Compiler $Compiler -CompilerVersion '$CompilerVersion' -Invocation $Invocation -EvidenceRef $EvidenceRef"
        tool_versions = $tools
        env = [ordered]@{
            set = [ordered]@{ ZCCACHE_MODE = 'COPY'; ZCCACHE_CACHE_DIR = '<work>\<cache_dir> per wrapped run'; ZCCACHE_SESSION_ID = 'per wrapped run, from session-start' }
            removed = $removed
        }
        started_at = $started; ended_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        compiler = $Compiler; compiler_version = $CompilerVersion; invocation = $Invocation; evidence_ref = $EvidenceRef
    }
    $record = New-ZqRecord ([ordered]@{ meta = $meta; runs = $runs; errors = $errs }) $jq $w
    [IO.File]::WriteAllText($outFile, $record + "`n")
    $r = $record | ConvertFrom-Json
    Write-Output "harness_pass=$($r.harness_pass): $($r.row.reason)"
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
