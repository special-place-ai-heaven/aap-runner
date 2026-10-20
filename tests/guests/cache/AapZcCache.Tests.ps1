# P13 zccache guest integration, Windows side: packaging, the per-job root, shim decisions with real processes against a
# fake zccache, shared-root binding, state and the host's trust class. No network, no real zccache, no compiler: the
# doubles are in fakes\. Pester 5, Windows PowerShell 5.1 and 7. Tags name the SAFETY checks a test covers;
# mutate.py runs only the tagged tests against a copy of guests\cache with that check broken (AAP_ZC_SRC).

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $script:Src = $(if ($env:AAP_ZC_SRC) { $env:AAP_ZC_SRC } else { Join-Path $script:Repo 'guests\cache' })
    Import-Module (Join-Path $script:Src 'windows\AapZcCache.psm1') -Force
    Import-Module (Join-Path $script:Src 'host\AapCacheTrust.psm1') -Force
    $script:Fakes = Join-Path $PSScriptRoot 'fakes'
    $script:Shell = (Get-Process -Id $PID).Path
    $script:Trees = New-Object System.Collections.Generic.List[string]
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Qualified = @(
        [ordered]@{ compiler = 'clang'; compiler_version = '18.1.3'; invocation = 'compile-object'; evidence_ref = 'parity/cache/qualification/evidence/x.json' }
        [ordered]@{ compiler = 'clang'; compiler_version = '18.1.3'; invocation = 'depfile'; evidence_ref = 'parity/cache/qualification/evidence/y.json' }
    )

    function New-Tree {
        $d = Join-Path ([IO.Path]::GetTempPath()) ('p13-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d
        $script:Trees.Add($d)
        return $d
    }
    function Get-Sha([byte[]]$Bytes) {
        $h = [Security.Cryptography.SHA256]::Create()
        -join ($h.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })
    }
    function Write-Json($Object, [string]$Path) { [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 8), $script:Utf8) }
    # name -> bytes; Link names a member stored with a symbolic-link mode.
    function New-Zip([string]$Path, $Entries, [string]$Link) {
        $fs = [IO.File]::Create($Path)
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($k in $Entries.Keys) {
            $e = $zip.CreateEntry($k)
            if ($k -eq $Link) { $e.ExternalAttributes = (0xA1FF -shl 16) }
            $s = $e.Open(); $s.Write($Entries[$k], 0, $Entries[$k].Length); $s.Dispose()
        }
        $zip.Dispose(); $fs.Dispose()
    }
    # A synthetic package: the fake zccache as the archive's members, with matching pins, provenance and toolchains.
    function New-Package([object[]]$Qualified = $script:Qualified, [hashtable]$ExtraEntries = @{}, [string]$Link) {
        $t = New-Tree
        $members = [ordered]@{}
        foreach ($n in 'fake-zccache.cmd', 'fake-zccache.ps1', 'fake-daemon.ps1') { $members[$n] = [IO.File]::ReadAllBytes((Join-Path $script:Fakes $n)) }
        $names = @{ 'fake-zccache.cmd' = 'zccache.cmd'; 'fake-zccache.ps1' = 'fake-zccache.ps1'; 'fake-daemon.ps1' = 'fake-daemon.ps1' }
        $entries = [ordered]@{}
        $pins = @()
        foreach ($n in $members.Keys) {
            $entries['zccache-test/' + $names[$n]] = $members[$n]
            $pins += [ordered]@{ name = $names[$n]; path = 'zccache-test/' + $names[$n]; bytes = $members[$n].Length; sha256 = Get-Sha $members[$n] }
        }
        foreach ($k in $ExtraEntries.Keys) { $entries[$k] = $ExtraEntries[$k] }
        $zip = Join-Path $t 'test.zip'
        New-Zip $zip $entries $Link
        $zb = [IO.File]::ReadAllBytes($zip)
        $wrappers = Join-Path $t 'wrappers.json'
        Write-Json ([ordered]@{ schema = 1; zccache = [ordered]@{ version = '1.15.6'; commit = '15ec9537af0d219e07b72ce2b3f97d5f68d72b5e' }
                platforms = [ordered]@{ 'windows-x86_64' = [ordered]@{ acquisition_entry = 'zccache-test'; archive = 'test.zip'; archive_sha256 = Get-Sha $zb
                        archive_bytes = $zb.Length; members = $pins; qualified = @($Qualified) } } }) $wrappers
        $prov = Join-Path $t 'test.zip.provenance.json'
        Write-Json ([ordered]@{ schema = 'aap-provenance/1'; name = 'zccache-test'; version = '1.15.6'; file_name = 'test.zip'; outcome = 'accepted'
                staging_check = 'strict'; sha256 = Get-Sha $zb; hash = [ordered]@{ verified = $true } }) $prov
        $null = New-Item -ItemType Directory -Path (Join-Path $t 'tc')
        $cc = Join-Path $t 'tc\fake-cc.cmd'
        Copy-Item -LiteralPath (Join-Path $script:Fakes 'fake-cc.cmd') -Destination $cc
        $tcs = Join-Path $t 'toolchains.json'
        Write-Json ([ordered]@{ toolchains = @([ordered]@{ compiler = 'clang'; compiler_version = '18.1.3'; path = $cc }) }) $tcs
        $src = Join-Path $t 'src'
        $null = New-Item -ItemType Directory -Path $src
        [IO.File]::WriteAllText((Join-Path $src 'a.c'), "int a;`r`n")
        [IO.File]::WriteAllText((Join-Path $src 'bad.c'), "#error deliberate`r`n")
        [pscustomobject]@{ Tree = $t; Zip = $zip; Wrappers = $wrappers; Provenance = $prov; Toolchains = $tcs; Cc = $cc; Src = $src
            Install = Join-Path $t 'install'; Job = Join-Path $t 'job'; Config = Join-Path $t 'job\state\config.json' }
    }
    function Install-Package($Pkg) { Install-AapZcCache -Archive $Pkg.Zip -Provenance $Pkg.Provenance -InstallDir $Pkg.Install -Toolchains $Pkg.Toolchains -Wrappers $Pkg.Wrappers }
    # The fake daemons: one fake-daemon.pid per cache root of every tree this run made.
    function Get-FakeDaemon([int[]]$Exclude = @()) {
        foreach ($t in $script:Trees) {
            foreach ($f in @(Get-ChildItem -LiteralPath $t -Recurse -Filter 'fake-daemon.pid' -ErrorAction SilentlyContinue)) {
                $id = [int](Get-Content -LiteralPath $f.FullName)
                if ($Exclude -notcontains $id) { Get-Process -Id $id -ErrorAction SilentlyContinue }
            }
        }
    }
    function Initialize-Package($Pkg, [long]$Budget = 100MB) {
        Install-Package $Pkg
        Initialize-AapZcJob -InstallDir $Pkg.Install -JobRoot $Pkg.Job -BudgetBytes $Budget
    }
    function Invoke-Shim($Pkg, [string[]]$Argv, [hashtable]$Env = @{}, [switch]$NoState) {
        $saved = @{}
        $Env['AAP_ZC_STATE'] = $(if ($NoState) { $null } else { $Pkg.Config })
        foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
        $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
        try {
            $line = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Pkg.Install 'zcshim.ps1')) + $Argv | ForEach-Object { '"' + $_ + '"' }) -join ' '
            $p = Start-Process -FilePath $script:Shell -ArgumentList $line -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
            [pscustomobject]@{ Code = $p.ExitCode; Out = [IO.File]::ReadAllText($o); Err = [IO.File]::ReadAllText($e) }
        } finally {
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            Remove-Item -LiteralPath $o, $e -ErrorAction SilentlyContinue
        }
    }
    function Get-Direct($Pkg, [string]$Source) {
        $out = Join-Path $Pkg.Tree ('direct-' + [guid]::NewGuid().ToString('N') + '.o')
        & cmd.exe /d /c ('"' + $Pkg.Cc + '" -c "' + $Source + '" -o "' + $out + '"') 2>$null
        [IO.File]::ReadAllBytes($out)
    }
    function Get-Journal($Pkg, [string]$Root = 'private') {
        $j = Join-Path $Pkg.Job ('roots\' + $Root + '\fake-journal.log')
        if (Test-Path -LiteralPath $j) { @(Get-Content -LiteralPath $j) } else { @() }
    }
    function Get-Flag($Pkg, [string]$Root = 'private') {
        $f = Join-Path $Pkg.Job ('shim\degraded-' + $Root)
        if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { $null }
    }
    function Compile($Pkg, [string]$Name = 'a.c', [hashtable]$Env = @{}, [string[]]$Extra = @()) {
        $out = Join-Path $Pkg.Tree ('out-' + [guid]::NewGuid().ToString('N') + '.o')
        $r = Invoke-Shim $Pkg (@($Pkg.Cc, '-c', (Join-Path $Pkg.Src $Name)) + $Extra + @('-o', $out)) $Env
        $r | Add-Member -NotePropertyName Output -NotePropertyValue $out -PassThru
    }
    function New-Binding($Pkg, [string]$Class = 'trusted', [string]$Runner = 'aap-w-1-7-0011aabb', [string]$Digest) {
        $cfg = Get-Content -Raw -LiteralPath $Pkg.Config | ConvertFrom-Json
        if (-not $Digest) { $Digest = $cfg.toolchain_digest }
        [ordered]@{ schema = 1; runner_name = $Runner; root_id = 'ns-00112233aabbccdd'; budget_bytes = 50MB
            namespace = [ordered]@{ repository_id = 4242; repository = 'org/repo'; trust_class = $Class; platform = 'windows-x86_64'; toolchain_digest = $Digest } }
    }
    function New-Mount($Pkg, $Binding, [string]$MarkerClass) {
        $m = Join-Path $Pkg.Tree ('mount-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $m
        $ns = [ordered]@{}
        foreach ($k in $Binding.namespace.Keys) { $ns[$k] = $Binding.namespace[$k] }
        if ($MarkerClass) { $ns.trust_class = $MarkerClass }
        Write-Json ([ordered]@{ schema = 1; root_id = $Binding.root_id; namespace = $ns }) (Join-Path $m 'aap-cache-root.json')
        return $m
    }
    function Connect-Binding($Pkg, $Binding, [string]$Mount, [string]$Runner = 'aap-w-1-7-0011aabb') {
        $bp = Join-Path $Pkg.Tree ('binding-' + [guid]::NewGuid().ToString('N') + '.json')
        if ($null -ne $Binding) { if ($Binding -is [string]) { [IO.File]::WriteAllText($bp, $Binding) } else { Write-Json $Binding $bp } }
        Connect-AapZcSharedRoot -JobRoot $Pkg.Job -BindingPath $bp -MountPath $Mount -RunnerName $Runner
    }
}

AfterAll {
    foreach ($p in @(Get-FakeDaemon)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    if (-not $env:AAP_ZC_KEEP) { foreach ($t in $script:Trees) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue } }
}

Describe 'Install-AapZcCache' {
    It 'installs the pinned members, toolchain identities and the receipt' {
        $pkg = New-Package
        Install-Package $pkg
        (Get-Sha ([IO.File]::ReadAllBytes((Join-Path $pkg.Install 'bin\zccache.cmd')))) | Should -Be (Get-Sha ([IO.File]::ReadAllBytes((Join-Path $script:Fakes 'fake-zccache.cmd'))))
        $tc = (Get-Content -Raw (Join-Path $pkg.Install 'toolchains.json') | ConvertFrom-Json).toolchains
        @($tc).Count | Should -Be 1
        $tc[0].sha256 | Should -Be (Get-Sha ([IO.File]::ReadAllBytes($pkg.Cc)))
        $r = Get-Content -Raw (Join-Path $pkg.Install 'install.json') | ConvertFrom-Json
        $r.toolchain_digest | Should -Be (Get-AapZcToolchainDigest $tc)
        Test-Path (Join-Path $pkg.Install 'zcshim.ps1') | Should -BeTrue
    }
    It 'refuses an archive that is not the pinned one, and installs nothing' -Tag 'WIN-ARCHIVE-HASH' {
        $pkg = New-Package
        $b = [IO.File]::ReadAllBytes($pkg.Zip); $b[$b.Length - 1] = $b[$b.Length - 1] -bxor 1; [IO.File]::WriteAllBytes($pkg.Zip, $b)
        { Install-Package $pkg } | Should -Throw '*AAP_ZC_ArchiveHash*'
        Test-Path $pkg.Install | Should -BeFalse
    }
    It 'refuses a provenance record that is <Case>' -Tag 'WIN-PROVENANCE' -TestCases @(
        @{ Case = 'unverified'; Key = 'hash'; Value = @{ verified = $false } }
        @{ Case = 'from a relaxed staging check'; Key = 'staging_check'; Value = 'relaxed' }
        @{ Case = 'rejected'; Key = 'outcome'; Value = 'rejected' }
        @{ Case = 'for another entry'; Key = 'name'; Value = 'docker-engine-windows-static' }
        @{ Case = 'for another hash'; Key = 'sha256'; Value = ('0' * 64) }
    ) {
        $pkg = New-Package
        $p = Get-Content -Raw $pkg.Provenance | ConvertFrom-Json
        $p.$Key = $Value
        Write-Json $p $pkg.Provenance
        { Install-Package $pkg } | Should -Throw '*AAP_ZC_Provenance*'
    }
    It 'refuses a member whose bytes differ from its pin' -Tag 'WIN-MEMBER-HASH' {
        $pkg = New-Package
        $w = Get-Content -Raw $pkg.Wrappers | ConvertFrom-Json
        $w.platforms.'windows-x86_64'.members[1].sha256 = ('0' * 64)
        Write-Json $w $pkg.Wrappers
        { Install-Package $pkg } | Should -Throw '*AAP_ZC_MemberHash*'
    }
    It 'refuses an archive with a <Case> member' -Tag 'WIN-ZIP-MEMBER' -TestCases @(
        @{ Case = 'parent-segment'; Name = 'zccache-test/../evil.txt'; Link = $null }
        @{ Case = 'absolute'; Name = '/evil.txt'; Link = $null }
        @{ Case = 'drive-letter'; Name = 'C:/evil.txt'; Link = $null }
        @{ Case = 'symbolic-link'; Name = 'zccache-test/link'; Link = 'zccache-test/link' }
    ) {
        $pkg = New-Package -ExtraEntries @{ $Name = [byte[]](1, 2, 3) } -Link $Link
        { Install-Package $pkg } | Should -Throw '*AAP_ZC_ArchiveMember*'
    }
    It 'refuses an install folder that is a junction' -Tag 'WIN-DIR-LINK' {
        $pkg = New-Package
        $target = New-Tree
        $null = New-Item -ItemType Junction -Path $pkg.Install -Value $target
        { Install-Package $pkg } | Should -Throw '*AAP_ZC_Link*'
        @(Get-ChildItem -LiteralPath $target).Count | Should -Be 0
    }
}

Describe 'Initialize-AapZcJob' {
    BeforeAll { Mock Get-AapZcDaemonProcess -ModuleName AapZcCache { Get-FakeDaemon -Exclude $Exclude } }

    It 'turns on nothing and starts no daemon when no pair is qualified (the state at the pin)' {
        $pkg = New-Package -Qualified @()
        $cfg = Initialize-Package $pkg
        $cfg.state | Should -Be 'direct'
        [IO.File]::ReadAllText((Join-Path $pkg.Job 'state\runner.env')) | Should -BeExactly ''
        Test-Path (Join-Path $pkg.Job 'roots\private\fake-daemon.pid') | Should -BeFalse
    }
    It 'turns on the CMake launchers, a private root, an explicit budget and a daemon for qualified pairs' -Tag 'WIN-BUDGET-SET', 'WIN-COPY-MODE' {
        $pkg = New-Package
        $cfg = Initialize-Package $pkg 100MB
        $cfg.state | Should -Be 'qualified'
        $cfg.roots.private.artifact_budget_bytes | Should -Be 75MB
        $cfg.roots.private.daemon.pid | Should -BeGreaterThan 0
        $envText = [IO.File]::ReadAllText((Join-Path $pkg.Job 'state\runner.env'))
        $envText | Should -Match ('AAP_ZC_STATE=' + [regex]::Escape($pkg.Config))
        $envText | Should -Match 'CMAKE_C_COMPILER_LAUNCHER=.*;-File;.*zcshim\.ps1'
        $envText | Should -Not -Match 'RUSTC_WRAPPER|ZCCACHE_'
        $seen = Get-Content -LiteralPath (Join-Path $pkg.Job 'roots\private\fake-env.log')
        $seen[0] | Should -Match 'MODE=COPY SIZE=78643200$'
    }
    It 'starts the daemon without credentials or inherited ZCCACHE_* variables' -Tag 'WIN-ENV-SECRET', 'WIN-ENV-ZCCACHE' {
        $pkg = New-Package
        $env:GH_TOKEN = 'synthetic-p13'; $env:HTTPS_PROXY = 'http://u:synthetic@proxy:3128'; $env:ZCCACHE_ENDPOINT = 'shared'
        try { $null = Initialize-Package $pkg } finally { Remove-Item Env:\GH_TOKEN, Env:\HTTPS_PROXY, Env:\ZCCACHE_ENDPOINT -ErrorAction SilentlyContinue }
        $seen = (Get-Content -LiteralPath (Join-Path $pkg.Job 'roots\private\fake-env.log')) -join "`n"
        $seen | Should -Not -Match '\bGH_TOKEN\b|\bHTTPS_PROXY\b|\bZCCACHE_ENDPOINT\b'
        $seen | Should -Match '\bZCCACHE_CACHE_DIR\b'
    }
    It 'is disabled when the installed zccache is not the pinned one' -Tag 'WIN-BOOT-BINARY' {
        $pkg = New-Package
        Install-Package $pkg
        Add-Content -LiteralPath (Join-Path $pkg.Install 'bin\fake-daemon.ps1') -Value '# changed'
        $cfg = Initialize-AapZcJob -InstallDir $pkg.Install -JobRoot $pkg.Job -BudgetBytes 100MB
        $cfg.state | Should -Be 'disabled'
        [IO.File]::ReadAllText((Join-Path $pkg.Job 'state\runner.env')) | Should -BeExactly ''
    }
    It 'drops a toolchain whose hash changed after the image was sealed' -Tag 'WIN-BOOT-TOOLCHAIN' {
        $pkg = New-Package
        Install-Package $pkg
        Add-Content -LiteralPath $pkg.Cc -Value 'rem changed'
        $cfg = Initialize-AapZcJob -InstallDir $pkg.Install -JobRoot $pkg.Job -BudgetBytes 100MB
        @($cfg.toolchains).Count | Should -Be 0
        $cfg.state | Should -Be 'direct'
    }
    It 'refuses a job root that is a junction' -Tag 'WIN-DIR-LINK' {
        $pkg = New-Package
        Install-Package $pkg
        $null = New-Item -ItemType Junction -Path $pkg.Job -Value (New-Tree)
        { Initialize-AapZcJob -InstallDir $pkg.Install -JobRoot $pkg.Job -BudgetBytes 100MB } | Should -Throw '*AAP_ZC_Link*'
    }
}

Describe 'zcshim: decisions and results (real processes, fake zccache)' {
    BeforeAll {
        Mock Get-AapZcDaemonProcess -ModuleName AapZcCache { Get-FakeDaemon -Exclude $Exclude }
        $script:Pkg = New-Package
        $null = Initialize-Package $script:Pkg
        $script:Expected = Get-Direct $script:Pkg (Join-Path $script:Pkg.Src 'a.c')
    }

    It 'cold then warm: output equals the direct compiler, the second call is a hit' -Tag 'WIN-SHIM-QUALIFIED', 'WIN-SHIM-DAEMON' {
        $before = @(Get-Journal $script:Pkg).Count
        $cold = Compile $script:Pkg
        $warm = Compile $script:Pkg
        $cold.Code | Should -Be 0; $warm.Code | Should -Be 0
        [IO.File]::ReadAllBytes($cold.Output) | Should -Be $script:Expected
        [IO.File]::ReadAllBytes($warm.Output) | Should -Be $script:Expected
        $j = @(Get-Journal $script:Pkg)
        $j.Count | Should -Be ($before + 2)
        $j[-1] | Should -Be 'hit'
        Get-Flag $script:Pkg | Should -BeNullOrEmpty
    }
    It 'a deliberate compile error stays an error with the direct exit code' {
        $r = Compile $script:Pkg 'bad.c'
        $r.Code | Should -Be 1
        $r.Err | Should -Match 'error: deliberate'
        Test-Path $r.Output | Should -BeFalse
        Get-Flag $script:Pkg | Should -BeNullOrEmpty
    }
    It 'builds directly, without calling zccache, for a <Case>' -Tag 'WIN-SHIM-QUALIFIED' -TestCases @(
        @{ Case = 'class that is not qualified (debug-pdb)'; Extra = @('-g') }
        @{ Case = 'call that cannot be classified (-E)'; Extra = @('-E') }
    ) {
        $before = @(Get-Journal $script:Pkg).Count
        $r = Compile $script:Pkg 'a.c' @{} $Extra
        $r.Code | Should -Be 0
        @(Get-Journal $script:Pkg).Count | Should -Be $before
    }
    It 'builds directly when AAP_ZC_STATE is not set' {
        $before = @(Get-Journal $script:Pkg).Count
        $out = Join-Path $script:Pkg.Tree 'nostate.o'
        $r = Invoke-Shim $script:Pkg @($script:Pkg.Cc, '-c', (Join-Path $script:Pkg.Src 'a.c'), '-o', $out) -NoState
        $r.Code | Should -Be 0
        [IO.File]::ReadAllBytes($out) | Should -Be $script:Expected
        @(Get-Journal $script:Pkg).Count | Should -Be $before
    }
    It 'never hands credentials or foreign ZCCACHE_* variables to zccache' -Tag 'WIN-ENV-SECRET', 'WIN-ENV-ZCCACHE', 'WIN-COPY-MODE' {
        $r = Compile $script:Pkg 'a.c' @{ ACTIONS_RUNTIME_TOKEN = 'synthetic-p13'; DATABASE_URL = 'postgres://a:synthetic@db/x'; ZCCACHE_MODE = 'LINK'; ZCCACHE_ENDPOINT = 'x' }
        $r.Code | Should -Be 0
        $last = @(Get-Content -LiteralPath (Join-Path $script:Pkg.Job 'roots\private\fake-env.log'))[-1]
        $last | Should -Not -Match '\bACTIONS_RUNTIME_TOKEN\b|\bDATABASE_URL\b|\bZCCACHE_ENDPOINT\b'
        $last | Should -Match 'MODE=COPY '
    }
    It 'no hardlink poisoning: writing into a delivered output does not change the next hit' -Tag 'WIN-COPY-MODE' {
        $null = Compile $script:Pkg
        $first = Compile $script:Pkg
        @(Get-Journal $script:Pkg)[-1] | Should -Be 'hit'
        $first.Code | Should -Be 0
        [IO.File]::AppendAllText($first.Output, 'APPENDED BY A BUILD STEP')
        $again = Compile $script:Pkg
        @(Get-Journal $script:Pkg)[-1] | Should -Be 'hit'
        [IO.File]::ReadAllBytes($again.Output) | Should -Be $script:Expected
    }
    It 'runs the 6 concurrent calls on one root to the direct result, with whole log lines' {
        $saved = $env:AAP_ZC_STATE; $env:AAP_ZC_STATE = $script:Pkg.Config
        $runs = @()
        try {
            foreach ($i in 1..6) {
                $out = Join-Path $script:Pkg.Tree ('conc-' + $i + '.o')
                $line = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Pkg.Install 'zcshim.ps1'), $script:Pkg.Cc, '-c', (Join-Path $script:Pkg.Src 'a.c'), '-o', $out) | ForEach-Object { '"' + $_ + '"' }) -join ' '
                $proc = Start-Process -FilePath $script:Shell -ArgumentList $line -NoNewWindow -PassThru
                $null = $proc.Handle  # Windows PowerShell 5.1 reports no ExitCode unless the handle was opened while running
                $runs += [pscustomobject]@{ Out = $out; P = $proc }
            }
            foreach ($r in $runs) { $r.P.WaitForExit() }
        } finally { $env:AAP_ZC_STATE = $saved }
        foreach ($r in $runs) { $r.P.ExitCode | Should -Be 0; [IO.File]::ReadAllBytes($r.Out) | Should -Be $script:Expected }
        $log = Get-Content -LiteralPath (Join-Path $script:Pkg.Job 'shim\shim.log')
        @($log | Where-Object { $_ -notmatch '^\d{4}-\d\d-\d\dT[\d:.]+Z (zccache|direct|fallback) ' }).Count | Should -Be 0
    }
}

Describe 'zcshim: faults' {
    BeforeAll { Mock Get-AapZcDaemonProcess -ModuleName AapZcCache { Get-FakeDaemon -Exclude $Exclude } }
    BeforeEach {
        $script:Pkg = New-Package
        $null = Initialize-Package $script:Pkg
        $script:Expected = Get-Direct $script:Pkg (Join-Path $script:Pkg.Src 'a.c')
    }

    It 'daemon down: builds directly without calling zccache and reports degraded' -Tag 'WIN-SHIM-DAEMON', 'WIN-DAEMON-ALIVE' {
        $cfg = Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json
        Stop-Process -Id $cfg.roots.private.daemon.pid -Force
        Start-Sleep -Milliseconds 300
        $r = Compile $script:Pkg
        $r.Code | Should -Be 0
        [IO.File]::ReadAllBytes($r.Output) | Should -Be $script:Expected
        @(Get-Journal $script:Pkg).Count | Should -Be 0
        Get-Flag $script:Pkg | Should -Be 'daemon-down'
        (Get-AapZcState -JobRoot $script:Pkg.Job).state | Should -Be 'degraded'
    }
    It 'a recycled daemon pid with another start time counts as down' -Tag 'WIN-DAEMON-ALIVE' {
        $cfg = Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json
        $cfg.roots.private.daemon.start = [long]$cfg.roots.private.daemon.start - 1
        Write-Json $cfg $script:Pkg.Config
        $r = Compile $script:Pkg
        $r.Code | Should -Be 0
        Get-Flag $script:Pkg | Should -Be 'daemon-down'
    }
    It 'zccache crashes: the direct compiler answers and the root is marked degraded' -Tag 'WIN-SHIM-FALLBACK' {
        $r = Compile $script:Pkg 'a.c' @{ FAKE_ZC_CRASH = '1' }
        $r.Code | Should -Be 0
        [IO.File]::ReadAllBytes($r.Output) | Should -Be $script:Expected
        Get-Flag $script:Pkg | Should -Be 'wrapper-failure'
        $after = Compile $script:Pkg
        $after.Code | Should -Be 0
        @(Get-Journal $script:Pkg).Count | Should -Be 0 -Because 'a degraded root is not used again'
    }
    It 'a corrupted cache entry that zccache rejects is rebuilt directly' -Tag 'WIN-SHIM-FALLBACK' {
        $null = Compile $script:Pkg 'a.c' @{ FAKE_ZC_VERIFY = '1' }
        $store = @(Get-ChildItem -LiteralPath (Join-Path $script:Pkg.Job 'roots\private\artifacts') -File | Where-Object { $_.Extension -eq '' })[0].FullName
        [IO.File]::WriteAllText($store, 'POISONED')
        $r = Compile $script:Pkg 'a.c' @{ FAKE_ZC_VERIFY = '1' }
        $r.Code | Should -Be 0
        [IO.File]::ReadAllBytes($r.Output) | Should -Be $script:Expected
        Get-Flag $script:Pkg | Should -Be 'wrapper-failure'
    }
    It 'a toolchain changed after boot builds directly' -Tag 'WIN-SHIM-TOOLCHAIN' {
        (Get-Item -LiteralPath $script:Pkg.Cc).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        $r = Compile $script:Pkg
        $r.Code | Should -Be 0
        @(Get-Journal $script:Pkg).Count | Should -Be 0
    }
    It 'over budget: stops using the root, builds directly and deletes nothing from it' -Tag 'WIN-OVER-BUDGET' {
        $cfg = Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json
        $logs = Join-Path $cfg.roots.private.dir 'logs'
        $null = New-Item -ItemType Directory -Force -Path $logs
        [IO.File]::WriteAllBytes((Join-Path $logs 'big.log'), (New-Object byte[] (26MB)))
        $files = @(Get-ChildItem -LiteralPath $cfg.roots.private.dir -Recurse -File | ForEach-Object { $_.FullName } | Sort-Object)
        $r = Compile $script:Pkg
        $r.Code | Should -Be 0
        [IO.File]::ReadAllBytes($r.Output) | Should -Be $script:Expected
        Get-Flag $script:Pkg | Should -Be 'over-budget'
        @(Get-Journal $script:Pkg).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $cfg.roots.private.dir -Recurse -File | ForEach-Object { $_.FullName } | Sort-Object) | Should -Be $files
    }
    It 'a root already marked degraded is not used' -Tag 'WIN-SHIM-FLAG' {
        [IO.File]::WriteAllText((Join-Path $script:Pkg.Job 'shim\degraded-private'), 'daemon-down')
        $r = Compile $script:Pkg
        $r.Code | Should -Be 0
        @(Get-Journal $script:Pkg).Count | Should -Be 0
    }
    It 'keeps the shim log bounded' -Tag 'WIN-LOG-BOUND' {
        $log = Join-Path $script:Pkg.Job 'shim\shim.log'
        [IO.File]::WriteAllBytes($log, (New-Object byte[] (1MB + 10)))
        $null = Compile $script:Pkg
        (Get-Item -LiteralPath $log).Length | Should -BeLessThan 4KB
        (Get-Item -LiteralPath ($log + '.1')).Length | Should -Be (1MB + 10)
    }
}

Describe 'Connect-AapZcSharedRoot' {
    BeforeAll { Mock Get-AapZcDaemonProcess -ModuleName AapZcCache { Get-FakeDaemon -Exclude $Exclude } }
    BeforeEach {
        $script:Pkg = New-Package
        $null = Initialize-Package $script:Pkg
    }

    It 'attaches a trusted root whose marker matches and moves wrapped calls to it' {
        $b = New-Binding $script:Pkg 'trusted'
        $m = New-Mount $script:Pkg $b
        $r = Connect-Binding $script:Pkg $b $m
        $r.Attached | Should -BeTrue
        $cfg = Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json
        $cfg.active_root | Should -Be 'shared'
        $cfg.roots.shared.dir | Should -Be (Join-Path $m 'root')
        $cfg.roots.shared.artifact_budget_bytes | Should -Be ([long][Math]::Floor(50MB * 3 / 4))
        $cfg.roots.shared.daemon.pid | Should -Not -Be $cfg.roots.private.daemon.pid
        $c = Compile $script:Pkg
        $c.Code | Should -Be 0
        @(Get-Journal $script:Pkg 'private').Count | Should -Be 0
        @(Get-Content -LiteralPath (Join-Path $m 'root\fake-journal.log')).Count | Should -Be 1
    }
    It 'an untrusted job never writes a trusted root' -Tag 'WIN-BIND-MARKER' {
        $b = New-Binding $script:Pkg 'untrusted'
        $m = New-Mount $script:Pkg $b 'trusted'
        $r = Connect-Binding $script:Pkg $b $m
        $r.Attached | Should -BeFalse
        $r.Reason | Should -Be 'marker-mismatch'
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).active_root | Should -Be 'private'
        Test-Path (Join-Path $m 'root') | Should -BeFalse -Because 'no daemon or file touched the trusted root'
        $null = Compile $script:Pkg
        Test-Path (Join-Path $m 'root') | Should -BeFalse
    }
    It 'a missing class means no shared root: <Case>' -Tag 'WIN-BIND-MISSING' -TestCases @(
        @{ Case = 'no binding file'; Mutate = 'none' }
        @{ Case = 'not JSON'; Mutate = 'garbage' }
        @{ Case = 'no namespace'; Mutate = 'no-namespace' }
        @{ Case = 'no trust class'; Mutate = 'no-class' }
        @{ Case = 'empty root id'; Mutate = 'no-root-id' }
    ) {
        $b = New-Binding $script:Pkg 'trusted'
        $m = New-Mount $script:Pkg $b
        $arg = switch ($Mutate) {
            'none' { $null }
            'garbage' { '{not json' }
            'no-namespace' { $b.Remove('namespace'); $b }
            'no-class' { $b.namespace.Remove('trust_class'); $b }
            'no-root-id' { $b.root_id = ''; $b }
        }
        $env:AAP_CACHE_TRUST_CLASS = 'trusted'
        try { $r = Connect-Binding $script:Pkg $arg $m } finally { Remove-Item Env:\AAP_CACHE_TRUST_CLASS }
        $r.Attached | Should -BeFalse
        $r.Reason | Should -Be 'binding-missing'
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).active_root | Should -Be 'private'
    }
    It 'refuses a trust class it does not know' -Tag 'WIN-BIND-CLASS' {
        $b = New-Binding $script:Pkg 'maybe'
        $r = Connect-Binding $script:Pkg $b (New-Mount $script:Pkg $b)
        $r.Reason | Should -Be 'trust-class-unknown'
    }
    It 'refuses a binding for another runner' -Tag 'WIN-BIND-RUNNER' {
        $b = New-Binding $script:Pkg 'trusted' 'aap-w-2-9-ffffffff'
        $r = Connect-Binding $script:Pkg $b (New-Mount $script:Pkg $b)
        $r.Reason | Should -Be 'runner-mismatch'
    }
    It 'refuses a root made for other toolchains' -Tag 'WIN-BIND-TOOLCHAIN' {
        $b = New-Binding $script:Pkg 'trusted' -Digest ('a' * 64)
        $r = Connect-Binding $script:Pkg $b (New-Mount $script:Pkg $b)
        $r.Reason | Should -Be 'toolchain-mismatch'
    }
    It 'refuses a root whose marker names another root id' -Tag 'WIN-BIND-MARKER' {
        $b = New-Binding $script:Pkg 'trusted'
        $m = New-Mount $script:Pkg $b
        $b.root_id = 'ns-ffffffffffffffff'
        (Connect-Binding $script:Pkg $b $m).Reason | Should -Be 'marker-mismatch'
    }
    It 'refuses a root that is a junction' -Tag 'WIN-BIND-LINK' {
        $b = New-Binding $script:Pkg 'trusted'
        $m = New-Mount $script:Pkg $b
        $null = New-Item -ItemType Junction -Path (Join-Path $m 'root') -Value (New-Tree)
        (Connect-Binding $script:Pkg $b $m).Reason | Should -Be 'root-is-link'
    }
    It 'binds at most once per job' -Tag 'WIN-BIND-ONCE' {
        $b = New-Binding $script:Pkg 'trusted'
        (Connect-Binding $script:Pkg $b (New-Mount $script:Pkg $b)).Attached | Should -BeTrue
        $b2 = New-Binding $script:Pkg 'untrusted'
        $b2.root_id = 'ns-0000000000000002'
        $r = Connect-Binding $script:Pkg $b2 (New-Mount $script:Pkg $b2)
        $r.Reason | Should -Be 'already-bound'
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).roots.shared.root_id | Should -Be 'ns-00112233aabbccdd'
    }
    It 'refuses when nothing is qualified' {
        $pkg = New-Package -Qualified @()
        $null = Initialize-Package $pkg
        $b = New-Binding $pkg 'trusted'
        (Connect-Binding $pkg $b (New-Mount $pkg $b)).Reason | Should -Be 'no-qualified-wrappers'
    }
}

Describe 'Get-AapZcState' {
    It 'reports unknown before initialization' {
        (Get-AapZcState -JobRoot (Join-Path (New-Tree) 'job')).state | Should -Be 'unknown'
    }
    It 'reports direct with byte counts when nothing is qualified' {
        Mock Get-AapZcDaemonProcess -ModuleName AapZcCache { Get-FakeDaemon -Exclude $Exclude }
        $pkg = New-Package -Qualified @()
        $null = Initialize-Package $pkg
        $s = Get-AapZcState -JobRoot $pkg.Job
        $s.state | Should -Be 'direct'
        $s.detail | Should -Match '^[ -~]{1,200}$'
        $s.bytes.private.budget | Should -Be 100MB
    }
}

Describe 'Get-AapZcToolchainDigest' {
    It 'matches the vector the Linux suite checks' {
        $v = @([pscustomobject]@{ compiler = 'clang'; compiler_version = '18.1.3'; sha256 = 'ab' }, [pscustomobject]@{ compiler = 'cl'; compiler_version = '1'; sha256 = 'cd' })
        Get-AapZcToolchainDigest $v | Should -Be 'c1c5e12c68673106853368b917e2fdb713e57cc23687647c6104b1aebf3bf11c'
        Get-AapZcToolchainDigest @() | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }
}

Describe 'Get-AapZcInvocation (shared vectors)' {
    It '<Name>' -TestCases @(
        $fx = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\classify.json') | ConvertFrom-Json
        foreach ($v in $fx.vectors) { if ($v.platforms -contains 'windows') { @{ Name = ($v.compiler + ' ' + ($v.args -join ' ')); V = $v } } }
    ) {
        $tmp = New-Tree
        $argv = @(foreach ($a in $V.args) {
                if ($a -eq '@RSP') { $f = Join-Path $tmp 'args.rsp'; [IO.File]::WriteAllText($f, $V.rsp); '@' + $f }
                elseif ($a -eq '@MISSING') { '@' + (Join-Path $tmp 'missing.rsp') }
                else { $a } })
        $got = Get-AapZcInvocation -Compiler $V.compiler -Arguments $argv
        if ($null -eq $V.classes) { $got | Should -BeNullOrEmpty } else { @($got) | Should -Be @($V.classes) }
    }
}

Describe 'ConvertTo-AapZcArg' {
    It 'round-trips <Name> through a real command line' -TestCases @(
        @{ Name = 'spaces'; A = 'C:\src dir\a.c' }
        @{ Name = 'embedded quotes'; A = '-DNAME="a b"' }
        @{ Name = 'trailing backslash with a space'; A = 'C:\out dir\' }
        @{ Name = 'backslashes before a quote'; A = 'a\\"b' }
        @{ Name = 'empty'; A = '' }
    ) {
        $py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $py) { Set-ItResult -Skipped -Because 'needs python to print its argv'; return }
        $o = [IO.Path]::GetTempFileName()
        try {
            $p = Start-Process -FilePath $py.Source -ArgumentList ('-I -B -c "import sys,json; print(json.dumps(sys.argv[1:]))" ' + (ConvertTo-AapZcArg $A)) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o
            $p.ExitCode | Should -Be 0
            @([IO.File]::ReadAllText($o) | ConvertFrom-Json) | Should -Be @($A)
        } finally { Remove-Item -LiteralPath $o -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-AapCacheTrustClass (contract rule 6)' {
    BeforeAll {
        function New-Run([string]$Event = 'push', [string]$Branch = 'main', [int]$Repo = 1, [int]$Head = 1) {
            [pscustomobject]@{ event = $Event; head_branch = $Branch; repository = [pscustomobject]@{ id = $Repo }; head_repository = [pscustomobject]@{ id = $Head } }
        }
    }
    It '<Case> is <Want>' -Tag 'TRUST-EVENT', 'TRUST-BRANCH', 'TRUST-HEAD-REPO', 'TRUST-TAG-UNKNOWN' -TestCases @(
        @{ Case = 'push to the default branch'; Run = @('push', 'main', 1, 1); Tag = $false; Want = 'trusted' }
        @{ Case = 'schedule'; Run = @('schedule', 'main', 1, 1); Tag = $false; Want = 'trusted' }
        @{ Case = 'workflow_dispatch on the default branch'; Run = @('workflow_dispatch', 'main', 1, 1); Tag = $false; Want = 'trusted' }
        @{ Case = 'pull_request'; Run = @('pull_request', 'main', 1, 2); Tag = $false; Want = 'untrusted' }
        @{ Case = 'pull_request_target on the default branch'; Run = @('pull_request_target', 'main', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'workflow_run on the default branch'; Run = @('workflow_run', 'main', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'issue_comment on the default branch'; Run = @('issue_comment', 'main', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'merge_group'; Run = @('merge_group', 'main', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'an event the rule does not name'; Run = @('repository_dispatch', 'main', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'push to dependabot/*'; Run = @('push', 'dependabot/npm/x', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'push to a branch named like the default in another case'; Run = @('push', 'Main', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'workflow_dispatch on a feature branch'; Run = @('workflow_dispatch', 'feature', 1, 1); Tag = $false; Want = 'untrusted' }
        @{ Case = 'push from another head repository'; Run = @('push', 'main', 1, 2); Tag = $false; Want = 'untrusted' }
        @{ Case = 'a tag push whose tag is named like the default branch'; Run = @('push', 'main', 1, 1); Tag = $true; Want = 'untrusted' }
        @{ Case = 'a push when the tag check did not run'; Run = @('push', 'main', 1, 1); Tag = $null; Want = $null }
    ) {
        $got = Get-AapCacheTrustClass -Run (New-Run @Run) -DefaultBranch 'main' -TagNamedLikeBranch $Tag
        if ($null -eq $Want) { $got | Should -BeNullOrEmpty } else { $got | Should -BeExactly $Want }
    }
    It 'an incomplete record yields no class' {
        Get-AapCacheTrustClass -Run $null -DefaultBranch 'main' -TagNamedLikeBranch $false | Should -BeNullOrEmpty
        Get-AapCacheTrustClass -Run (New-Run) -DefaultBranch '' -TagNamedLikeBranch $false | Should -BeNullOrEmpty
        Get-AapCacheTrustClass -Run ([pscustomobject]@{ event = 'push'; head_branch = 'main'; repository = $null; head_repository = $null }) -DefaultBranch 'main' -TagNamedLikeBranch $false | Should -BeNullOrEmpty
    }
}
