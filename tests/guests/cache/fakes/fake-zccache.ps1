# Fake zccache for the P13 tests. Not a cache implementation: it models what the guest integration relies on.
#   session-start ... | session-end ID  start one fake daemon per cache root (fake-daemon.pid), print a session id
#   COMPILER ARGS...                    key = hash of compiler, arguments (not the -o name) and input. A hit delivers
#                                       the stored output: ZCCACHE_MODE=COPY copies it, any other mode hardlinks it
#                                       (the poisoning hazard).
#                                       A miss runs the compiler and stores its output. fake-journal.log gets hit/miss.
# Every call appends the environment variable NAMES it received (never values) to fake-env.log.
# Faults: FAKE_ZC_CRASH=1 exits 139 at once; with FAKE_ZC_VERIFY=1 a stored entry that no longer matches its .sha
# sidecar is refused with exit 5 (a cache that detects a corrupted entry); FAKE_ZC_HANG=SECONDS records this process in
# fake-client.pid and sleeps that long before exiting 0 (a hung client); with FAKE_ZC_LATE=SECONDS it first starts a
# child that writes LATE to the -o file after that long (a straggler the timeout must stop).
# FAKE_ZC_ARGV_LOG=PATH writes the arguments it received to PATH as JSON, writes the -o file and exits 0, before
# anything else; it then needs no cache root. The arguments come from the process command line, as zcshim.ps1 takes them.
# A hit delivers the object and, with -MD/-MMD, the depfile. Delivery faults on a hit, all exiting 0:
# FAKE_ZC_NODELIVER=1 writes nothing, FAKE_ZC_EMPTY=1 an empty object, FAKE_ZC_LINK=1 a symbolic link to the entry
# (zccache.cmd runs this under PowerShell 7 then, which can make one in developer mode). FAKE_ZC_PROGRESS=N first prints N of zccache's
# progress lines to stderr.
# FAKE_ZC_STDIN=1 (P04.1) appends eof to fake-stdin.log and carries on when this call's stdin is at EOF; an open or
# feeding stdin is appended as open and fails the call with exit 7, as a client handed the caller's stdin would hang.
$ErrorActionPreference = 'Stop'
$all = [Environment]::GetCommandLineArgs()
$i = 1
while ($i -lt $all.Count -and $all[$i] -ne '-File') { $i++ }
$argv = @($all | Select-Object -Skip ($i + 2))
if ($env:FAKE_ZC_ARGV_LOG) {
    [IO.File]::WriteAllText($env:FAKE_ZC_ARGV_LOG, (ConvertTo-Json -InputObject ([object[]]$argv) -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $o = [array]::IndexOf([string[]]$argv, '-o')
    if ($o -ge 0 -and $o + 1 -lt $argv.Count) { [IO.File]::WriteAllText($argv[$o + 1], 'OBJ') }  # delivered, as the shim checks
    exit 0
}
function Add-Line([string]$Path, [string]$Line) {
    for ($i = 0; $i -lt 50; $i++) { try { [IO.File]::AppendAllText($Path, $Line + "`n"); return } catch { Start-Sleep -Milliseconds 20 } }
}
function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$root = $env:ZCCACHE_CACHE_DIR
if (-not $root) { [Console]::Error.WriteLine('fake-zccache: no ZCCACHE_CACHE_DIR'); exit 9 }
$null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'artifacts')
$names = @(Get-ChildItem Env: | ForEach-Object { $_.Name } | Sort-Object)
Add-Line (Join-Path $root 'fake-env.log') (($names -join ' ') + ' MODE=' + $env:ZCCACHE_MODE + ' SIZE=' + $env:ZCCACHE_CACHE_SIZE_BYTES)
if ($env:FAKE_ZC_STDIN -eq '1') {
    $buf = New-Object byte[] 1
    $t = [Console]::OpenStandardInput().ReadAsync($buf, 0, 1)
    if (-not $t.Wait(2000)) { Add-Line (Join-Path $root 'fake-stdin.log') 'open'; exit 7 }
    if ($t.Result -gt 0) { Add-Line (Join-Path $root 'fake-stdin.log') 'open'; exit 7 }
    Add-Line (Join-Path $root 'fake-stdin.log') 'eof'
}
if ($env:FAKE_ZC_CRASH -eq '1') { exit 139 }
if ($argv[0] -eq 'session-start') {
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
if ($argv[0] -eq 'session-end') { exit 0 }
for ($i = 0; $i -lt [int]$env:FAKE_ZC_PROGRESS; $i++) { [Console]::Error.Write("zccache[info][Q]: daemon under load: compiling, $($i + 2) compiles in flight`n") }
$cc = $argv[0]
$rest = @($argv | Select-Object -Skip 1)
$out = $null; $in = $null; $keyArgs = @(); $mf = $null; $md = $false
for ($i = 0; $i -lt $rest.Count; $i++) {
    if ($rest[$i] -eq '-o' -and $i + 1 -lt $rest.Count) { $out = $rest[$i + 1]; $i++; continue }
    if ($rest[$i] -ceq '-MF' -and $i + 1 -lt $rest.Count) { $mf = $rest[$i + 1] }
    if ($rest[$i] -cin @('-MD', '-MMD')) { $md = $true }
    if (Test-Path -LiteralPath $rest[$i] -PathType Leaf) { $in = $rest[$i] }
    $keyArgs += $rest[$i]
}
if ($env:FAKE_ZC_HANG) {
    Set-Content -LiteralPath (Join-Path $root 'fake-client.pid') -Value $PID
    if ($env:FAKE_ZC_LATE -and $out) {
        $late = "Start-Sleep -Seconds $([int]$env:FAKE_ZC_LATE); [IO.File]::WriteAllText('$out', 'LATE')"
        $null = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $late) -WindowStyle Hidden -PassThru
    }
    Start-Sleep -Seconds ([int]$env:FAKE_ZC_HANG)
    exit 0
}
$keyText = $cc + "`n" + ($keyArgs -join "`n") + "`n" + $(if ($in) { [IO.File]::ReadAllText($in) } else { '' })
$h = [Security.Cryptography.SHA256]::Create()
$key = -join ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyText)) | ForEach-Object { $_.ToString('x2') })
$store = Join-Path $root ('artifacts\' + $key)
$dep = $(if ($md -and $out) { if ($mf) { $mf } else { [IO.Path]::ChangeExtension($out, '.d') } })
if ($out -and (Test-Path -LiteralPath $store) -and (-not $dep -or (Test-Path -LiteralPath ($store + '.dep')))) {
    if ($env:FAKE_ZC_VERIFY -eq '1' -and (Get-Sha $store) -ne (Get-Content -LiteralPath ($store + '.sha'))) { [Console]::Error.WriteLine('fake-zccache: corrupt entry'); exit 5 }
    Add-Line (Join-Path $root 'fake-journal.log') 'hit'
    if ($env:FAKE_ZC_NODELIVER -eq '1') { exit 0 }
    if ($env:FAKE_ZC_EMPTY -eq '1') { [IO.File]::WriteAllBytes($out, [byte[]]@()); exit 0 }
    if ($env:FAKE_ZC_LINK -eq '1') {
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        $null = New-Item -ItemType SymbolicLink -Path $out -Value $store
        exit 0
    }
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    if ($env:ZCCACHE_MODE -eq 'COPY') { Copy-Item -LiteralPath $store -Destination $out } else { $null = New-Item -ItemType HardLink -Path $out -Value $store }
    if ($dep) { Copy-Item -LiteralPath ($store + '.dep') -Destination $dep -Force }
    exit 0
}
Add-Line (Join-Path $root 'fake-journal.log') 'miss'
& $cc @rest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($out -and (Test-Path -LiteralPath $out)) {
    if ($dep -and (Test-Path -LiteralPath $dep)) { Copy-Item -LiteralPath $dep -Destination ($store + '.dep') -Force }
    $tmp = $store + '.' + $PID + '.tmp'
    Copy-Item -LiteralPath $out -Destination $tmp
    Move-Item -LiteralPath $tmp -Destination $store -Force
    Set-Content -LiteralPath ($store + '.sha') -Value (Get-Sha $store)
}
exit 0
