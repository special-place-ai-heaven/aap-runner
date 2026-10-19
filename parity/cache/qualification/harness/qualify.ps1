# zccache 1.15.6 qualification harness, Windows x86_64. LAB ONLY (P13/P22), see ../README.md.
#
# Runs one (compiler, invocation) pair through uncached, cold, warm and poisoned-cache builds
# plus the deliberate-error case, compares exit codes and artifact hashes, counts warm hits
# from the per-session compile journal and writes one evidence record. It never decides the
# matrix: a reviewer copies the record's `row` into windows-x86_64.json.
#
# Exit codes: 0 record written (read its verdict), 2 usage, 3 refused (not a lab), 4 the zccache
# binary is not the pinned release binary.
#
# Windows PowerShell 5.1 and PowerShell 7. Run from a Developer PowerShell for cl/link.
[CmdletBinding()]
param(
    [string]$Compiler,          # matrix compiler name, e.g. clang-cl
    [string]$CompilerPath,      # the real compiler executable
    [string]$CompilerVersion,   # exactly the matrix row's compiler_version
    [string]$Invocation,        # matrix invocation class
    [string]$Zccache,           # unpacked zccache.exe from the pinned archive
    [string]$Out,               # where the evidence JSON is written
    [string]$EvidenceRef,       # repo path the reviewer will commit the record under
    [string]$PrereqCompiler,    # link/lld-link only: cl.exe or clang-cl.exe that builds the objects
    [string]$Work,              # empty scratch directory
    [string[]]$ExtraMarkerRoot  # tests only: more roots to probe for live-install markers
)

$ZqBinarySha256 = '41de068f3024a1bcbfea8ad488455c648ee07903e09e9fca4d663436789d0731'
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

# Argument list and primary artifact for one run. $Case is 'ok' or 'error'.
function Get-ZqCommand([string]$Compiler, [string]$Invocation, [string]$Src, [string]$OutDir, [string]$Case, [string]$Rsp, [string]$Pre) {
    $bad = $Case -eq 'error'
    $c = if ($bad) { 'error.c' } else { 'hello.c' }
    if ($Compiler -eq 'clang++') { $c = if ($bad) { 'error.cpp' } else { 'hello.cpp' } }
    $source = Join-Path $Src $c
    switch -Regex ($Compiler) {
        '^rustc$' {
            $rs = Join-Path $Src $(if ($bad) { 'error.rs' } else { 'hello.rs' })
            switch ($Invocation) {
                'rustc-wrapper' {
                    $lib = Join-Path $Src $(if ($bad) { 'error.rs' } else { 'lib.rs' })
                    return @{ Args = @('--crate-name', 'hello', '--edition', '2021', '--crate-type', 'lib', '--emit=metadata,link', $lib, '--out-dir', $OutDir); Primary = 'libhello.rlib' }
                }
                'debug-pdb' { return @{ Args = @('-C', 'debuginfo=2', $rs, '-o', (Join-Path $OutDir 'hello.exe')); Primary = 'hello.exe' } }
                default { return @{ Args = @($rs, '-o', (Join-Path $OutDir 'hello.exe')); Primary = 'hello.exe' } }
            }
        }
        '^clang(\+\+)?$' {
            $o = Join-Path $OutDir 'hello.o'
            switch ($Invocation) {
                'compile-pch' {
                    $lang = if ($Compiler -eq 'clang++') { 'c++-header' } else { 'c-header' }
                    $h = if ($bad) { $source } else { Join-Path $Src 'hello.h' }
                    return @{ Args = @('-x', $lang, $h, '-o', (Join-Path $OutDir 'hello.h.pch')); Primary = 'hello.h.pch' }
                }
                'response-file' {
                    # Forward slashes: GNU-style response-file quoting treats backslash as an escape.
                    $line = (@('-c', $source, '-o', $o) | ForEach-Object { '"' + ($_ -replace '\\', '/') + '"' }) -join ' '
                    [IO.File]::WriteAllText($Rsp, $line)
                    return @{ Args = @("@$Rsp"); Primary = 'hello.o' }
                }
                'depfile' { return @{ Args = @('-c', $source, '-o', $o, '-MD', '-MF', (Join-Path $OutDir 'hello.d')); Primary = 'hello.o' } }
                default { return @{ Args = @('-c', $source, '-o', $o); Primary = 'hello.o' } }
            }
        }
        '^(clang-cl|cl)$' {
            $fo = '/Fo' + (Join-Path $OutDir 'hello.obj')
            switch ($Invocation) {
                'compile-pch' { return @{ Args = @('/nologo', '/c', '/Brepro', '/Ychello.h', $source, ('/Fp' + (Join-Path $OutDir 'hello.pch')), $fo); Primary = 'hello.pch' } }
                'debug-pdb' { return @{ Args = @('/nologo', '/c', '/Brepro', '/Zi', $source, $fo, ('/Fd' + (Join-Path $OutDir 'hello.pdb'))); Primary = 'hello.obj' } }
                'response-file' {
                    [IO.File]::WriteAllText($Rsp, ((@('/nologo', '/c', '/Brepro', $source, $fo) | ForEach-Object { '"' + $_ + '"' }) -join ' '))
                    return @{ Args = @("@$Rsp"); Primary = 'hello.obj' }
                }
                default { return @{ Args = @('/nologo', '/c', '/Brepro', $source, $fo); Primary = 'hello.obj' } }
            }
        }
        '^(link|lld-link)$' {
            $obj = Join-Path $Pre $(if ($bad) { 'unresolved.obj' } else { 'hello.obj' })
            return @{ Args = @('/nologo', '/Brepro', $obj, ('/OUT:' + (Join-Path $OutDir 'hello.exe'))); Primary = 'hello.exe' }
        }
    }
    throw "USAGE: no command for $Compiler/$Invocation"
}

function Get-ZqArtifact([string]$Dir) {
    $h = [ordered]@{}
    Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        $h[$_.FullName.Substring($Dir.Length).TrimStart('\')] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $h
}

function Test-ZqSame($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $false }
    (@($A.Keys) -join '|') -eq (@($B.Keys) -join '|') -and (@($A.Values) -join '|') -eq (@($B.Values) -join '|')
}

# Journal outcomes per README 1240-1273 at the pin: hit, miss, error, link_hit, link_miss.
function Get-ZqHitCount([string]$Journal) {
    if (-not (Test-Path -LiteralPath $Journal)) { return $null }
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($Journal)) {
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if ($e.outcome -in @('hit', 'link_hit')) { $n++ }
    }
    $n
}

# One evidence record. The row is `qualified` only when every check is true.
function New-ZqRecord($Meta, $Runs, $ErrorRuns, $Hits) {
    $ok = $Runs.uncached
    $checks = [ordered]@{
        ok_exit_zero          = $ok.exit -eq 0
        exit_codes_equal      = ($Runs.cold.exit -eq $ok.exit) -and ($Runs.warm.exit -eq $ok.exit)
        artifacts_equal       = (Test-ZqSame $ok.artifacts $Runs.cold.artifacts) -and (Test-ZqSame $ok.artifacts $Runs.warm.artifacts)
        cold_has_no_hits      = $Hits.cold -eq 0
        warm_has_hits         = $null -ne $Hits.warm -and $Hits.warm -gt 0
        errors_stay_errors    = @($ErrorRuns.Values | Where-Object { $_.exit -eq 0 -or $_.primary_present }).Count -eq 0 -and $ErrorRuns.Count -eq 3
        poisoned_entry_unused = $null -ne $Runs.poisoned -and $Runs.poisoned.exit -eq $ok.exit -and (Test-ZqSame $ok.artifacts $Runs.poisoned.artifacts)
    }
    $failed = @($checks.Keys | Where-Object { -not $checks[$_] })
    $mode = if ($failed.Count -eq 0) { 'qualified' } else { 'direct' }
    $reason = if ($mode -eq 'qualified') { 'uncached/cold/warm/poisoned exits and artifacts equal; errors stay errors; warm hit observed' } else { 'lab run failed: ' + ($failed -join ',') }
    [ordered]@{
        schema = 1; item = 'P04'; platform = 'windows-x86_64'
        zccache_binary_sha256 = $Meta.zccache_sha256
        compiler_version_observed = $Meta.observed
        started_at = $Meta.started; ended_at = (Get-Date).ToUniversalTime().ToString('o')
        runs = $Runs; error_runs = $ErrorRuns; hits = $Hits; checks = $checks
        row = [ordered]@{ compiler = $Meta.compiler; compiler_version = $Meta.version; invocation = $Meta.invocation; mode = $mode
            evidence_ref = $(if ($mode -eq 'qualified') { $Meta.evidence_ref } else { $null }); reason = $reason.Substring(0, [Math]::Min(200, $reason.Length)) }
    }
}

function Invoke-ZqRun([string]$Exe, [string[]]$Argv, [string]$Log) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Exe @Argv > "$Log.out" 2> "$Log.err"; $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
}

function Invoke-ZqMain {
    Assert-ZqLab (Get-ZqMarkerPath $ExtraMarkerRoot)
    Test-ZqArg -Compiler $Compiler -CompilerPath $CompilerPath -CompilerVersion $CompilerVersion -Invocation $Invocation `
        -Zccache $Zccache -Out $Out -EvidenceRef $EvidenceRef -PrereqCompiler $PrereqCompiler -Work $Work
    $zsha = (Get-FileHash -LiteralPath $Zccache -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($zsha -ne $ZqBinarySha256) { throw "BINARY: $Zccache is $zsha, not the pinned 1.15.6 zccache.exe" }

    $started = (Get-Date).ToUniversalTime().ToString('o')
    $null = New-Item -ItemType Directory -Force -Path $Work
    $Work = (Resolve-Path -LiteralPath $Work).Path
    $src = Join-Path $Work $(if ($Invocation -eq 'path-with-spaces') { 'src with spaces' } else { 'src' })
    $null = New-Item -ItemType Directory -Force -Path $src, (Join-Path $Work 'logs'), (Join-Path $Work 'pre')
    Copy-Item -Path (Join-Path $PSScriptRoot 'fixtures\*') -Destination $src
    $outDir = Join-Path $src 'out'
    $pre = Join-Path $Work 'pre'
    if ($Compiler -in @('link', 'lld-link')) {
        foreach ($n in @('hello', 'unresolved')) {
            $rc = Invoke-ZqRun $PrereqCompiler @('/nologo', '/c', '/Brepro', (Join-Path $src "$n.c"), ('/Fo' + (Join-Path $pre "$n.obj"))) (Join-Path $Work "logs\pre-$n")
            if ($rc -ne 0) { throw "USAGE: prerequisite compile of $n.c failed ($rc)" }
        }
    }
    $null = Invoke-ZqRun $CompilerPath @('--version') (Join-Path $Work 'logs\version')  # cl prints its banner to stderr
    $observed = (@(Get-Content -LiteralPath (Join-Path $Work 'logs\version.out'), (Join-Path $Work 'logs\version.err') -ErrorAction SilentlyContinue) | Where-Object { $_.Trim() } | Select-Object -First 1)

    # Fresh, isolated cache root and COPY delivery (contract rule 6).
    $env:ZCCACHE_CACHE_DIR = Join-Path $Work 'cache'
    $env:ZCCACHE_MODE = 'COPY'
    Remove-Item Env:\ZCCACHE_DISABLE -ErrorAction SilentlyContinue
    $rsp = Join-Path $Work 'args.rsp'
    $runs = [ordered]@{}; $errs = [ordered]@{}; $hits = [ordered]@{}

    foreach ($case in @('ok', 'error')) {
        foreach ($phase in @('uncached', 'cold', 'warm', 'poisoned')) {
            if ($case -eq 'error' -and $phase -eq 'poisoned') { continue }
            if ($case -eq 'ok' -and $phase -eq 'poisoned') {
                $store = Join-Path $env:ZCCACHE_CACHE_DIR 'artifacts'
                $files = @(Get-ChildItem -LiteralPath $store -Recurse -File -ErrorAction SilentlyContinue)
                if ($files.Count -eq 0) { $runs.poisoned = $null; continue }  # store layout to confirm in lab
                foreach ($f in $files) { $f.IsReadOnly = $false; [IO.File]::WriteAllBytes($f.FullName, [Text.Encoding]::ASCII.GetBytes('P04-POISON')) }
            }
            if ($case -eq 'error' -and $phase -eq 'cold') { Remove-Item -LiteralPath $env:ZCCACHE_CACHE_DIR -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item -ItemType Directory -Path $outDir
            $cmd = Get-ZqCommand $Compiler $Invocation $src $outDir $case $rsp $pre
            $log = Join-Path $Work "logs\$case-$phase"
            if ($phase -eq 'uncached') {
                $rc = Invoke-ZqRun $CompilerPath $cmd.Args $log
            } else {
                $journal = "$log.jsonl"
                $sid = $null
                try { $sid = ((& $Zccache session-start --journal $journal) | Out-String | ConvertFrom-Json).session_id } catch { $sid = $null }
                if ($sid) { $env:ZCCACHE_SESSION_ID = $sid }
                $rc = Invoke-ZqRun $Zccache (@($CompilerPath) + $cmd.Args) $log
                if ($sid) { $null = Invoke-ZqRun $Zccache @('session-end', $sid, '--json') "$log.session"; Remove-Item Env:\ZCCACHE_SESSION_ID }
                if ($case -eq 'ok' -and $phase -ne 'poisoned') { $hits[$phase] = $(if ($sid) { Get-ZqHitCount $journal } else { $null }) }
            }
            $entry = [ordered]@{ exit = $rc; artifacts = (Get-ZqArtifact $outDir); primary_present = (Test-Path -LiteralPath (Join-Path $outDir $cmd.Primary)) }
            if ($case -eq 'ok') { $runs[$phase] = $entry } else { $errs[$phase] = $entry }
        }
    }
    $meta = @{ zccache_sha256 = $zsha; observed = [string]$observed; started = $started; compiler = $Compiler; version = $CompilerVersion; invocation = $Invocation; evidence_ref = $EvidenceRef }
    $record = New-ZqRecord $meta $runs $errs $hits
    [IO.File]::WriteAllText($Out, ($record | ConvertTo-Json -Depth 8))
    Write-Output "$($record.row.mode): $($record.row.reason)"
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
