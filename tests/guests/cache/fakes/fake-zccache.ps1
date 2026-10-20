# Fake zccache for the P13 tests. Not a cache implementation: it models what the guest integration relies on.
#   session-start ... | session-end ID  start one fake daemon per cache root (fake-daemon.pid), print a session id
#   COMPILER ARGS...                    key = hash of compiler, arguments (not the -o name) and input. A hit delivers
#                                       the stored output: ZCCACHE_MODE=COPY copies it, any other mode hardlinks it
#                                       (the poisoning hazard).
#                                       A miss runs the compiler and stores its output. fake-journal.log gets hit/miss.
# Every call appends the environment variable NAMES it received (never values) to fake-env.log.
# Faults: FAKE_ZC_CRASH=1 exits 139 at once; with FAKE_ZC_VERIFY=1 a stored entry that no longer matches its .sha
# sidecar is refused with exit 5 (a cache that detects a corrupted entry).
$ErrorActionPreference = 'Stop'
function Add-Line([string]$Path, [string]$Line) {
    for ($i = 0; $i -lt 50; $i++) { try { [IO.File]::AppendAllText($Path, $Line + "`n"); return } catch { Start-Sleep -Milliseconds 20 } }
}
function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$root = $env:ZCCACHE_CACHE_DIR
if (-not $root) { [Console]::Error.WriteLine('fake-zccache: no ZCCACHE_CACHE_DIR'); exit 9 }
$null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'artifacts')
$names = @(Get-ChildItem Env: | ForEach-Object { $_.Name } | Sort-Object)
Add-Line (Join-Path $root 'fake-env.log') (($names -join ' ') + ' MODE=' + $env:ZCCACHE_MODE + ' SIZE=' + $env:ZCCACHE_CACHE_SIZE_BYTES)
if ($env:FAKE_ZC_CRASH -eq '1') { exit 139 }
if ($args[0] -eq 'session-start') {
    $pidFile = Join-Path $root 'fake-daemon.pid'
    $alive = $false
    if (Test-Path -LiteralPath $pidFile) { $alive = [bool](Get-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue) }
    if (-not $alive) {
        # ShellExecute does not hand this process's (captured) pipes to the daemon.
        $daemon = '"' + (Join-Path $PSScriptRoot 'fake-daemon.ps1') + '"'
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $daemon) -WindowStyle Hidden -PassThru
        Set-Content -LiteralPath $pidFile -Value $p.Id
    }
    '{"session_id":"fake-session"}'
    exit 0
}
if ($args[0] -eq 'session-end') { exit 0 }
$cc = $args[0]
$rest = @($args | Select-Object -Skip 1)
$out = $null; $in = $null; $keyArgs = @()
for ($i = 0; $i -lt $rest.Count; $i++) {
    if ($rest[$i] -eq '-o' -and $i + 1 -lt $rest.Count) { $out = $rest[$i + 1]; $i++; continue }
    if (Test-Path -LiteralPath $rest[$i] -PathType Leaf) { $in = $rest[$i] }
    $keyArgs += $rest[$i]
}
$keyText = $cc + "`n" + ($keyArgs -join "`n") + "`n" + $(if ($in) { [IO.File]::ReadAllText($in) } else { '' })
$h = [Security.Cryptography.SHA256]::Create()
$key = -join ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyText)) | ForEach-Object { $_.ToString('x2') })
$store = Join-Path $root ('artifacts\' + $key)
if ($out -and (Test-Path -LiteralPath $store)) {
    if ($env:FAKE_ZC_VERIFY -eq '1' -and (Get-Sha $store) -ne (Get-Content -LiteralPath ($store + '.sha'))) { [Console]::Error.WriteLine('fake-zccache: corrupt entry'); exit 5 }
    Add-Line (Join-Path $root 'fake-journal.log') 'hit'
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    if ($env:ZCCACHE_MODE -eq 'COPY') { Copy-Item -LiteralPath $store -Destination $out } else { $null = New-Item -ItemType HardLink -Path $out -Value $store }
    exit 0
}
Add-Line (Join-Path $root 'fake-journal.log') 'miss'
& $cc @rest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($out -and (Test-Path -LiteralPath $out)) {
    $tmp = $store + '.' + $PID + '.tmp'
    Copy-Item -LiteralPath $out -Destination $tmp
    Move-Item -LiteralPath $tmp -Destination $store -Force
    Set-Content -LiteralPath ($store + '.sha') -Value (Get-Sha $store)
}
exit 0
