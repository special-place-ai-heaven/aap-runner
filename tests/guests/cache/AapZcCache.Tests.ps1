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
    $script:Pwsh = $(if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' })
    $script:Trees = New-Object System.Collections.Generic.List[string]
    # Everything this run writes lives under one run root in the temp folder; AfterAll stops every process started from
    # it and fails the run when the root or one of those processes survives.
    $script:RunRoot = Join-Path ([IO.Path]::GetTempPath()) ('p13-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:RunRoot
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Qualified = @(
        [ordered]@{ compiler = 'clang'; compiler_version = '18.1.3'; invocation = 'compile-object'; evidence_ref = 'parity/cache/qualification/evidence/x.json' }
        [ordered]@{ compiler = 'clang'; compiler_version = '18.1.3'; invocation = 'depfile'; evidence_ref = 'parity/cache/qualification/evidence/y.json' }
    )

    function New-Tree {
        $d = Join-Path $script:RunRoot ('t' + $script:Trees.Count)
        $null = New-Item -ItemType Directory -Path $d
        $script:Trees.Add($d)
        return $d
    }
    function New-TempName { Join-Path $script:RunRoot ([guid]::NewGuid().ToString('N') + '.tmp') }
    # The processes started from this run's root: the fakes run from a tree's install folder.
    function Get-RunProcess {
        $name = Split-Path -Leaf $script:RunRoot
        @(Get-CimInstance -ClassName Win32_Process | Where-Object { $_.ProcessId -ne $PID -and ([string]$_.CommandLine).Contains($name) })
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
    # The fake daemons and hung fake clients of every tree this run made (fake-daemon.pid, fake-client.pid).
    function Get-FakePidFile {
        foreach ($t in $script:Trees) {
            foreach ($f in @(Get-ChildItem -LiteralPath $t -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'fake-daemon.pid' -or $_.Name -eq 'fake-client.pid' })) {
                [pscustomobject]@{ Tree = $t; File = $f; Id = [int](Get-Content -LiteralPath $f.FullName) }
            }
        }
    }
    # Stands in for Get-AapZcProcessList: the fakes run as powershell.exe, so each is listed as if it ran where zccache
    # 1.15.6 runs it, with its real command line: a daemon from the copy zccache deploys into its root
    # (ROOT\v1.15.6\zccache-daemon.exe), a client, or a stray daemon zccache ran in place, from its tree's installed
    # bin folder. A hung client is listed as just started, the worst case.
    function Get-FakeProcessList {
        foreach ($x in @(Get-FakePidFile)) {
            $p = Get-Process -Id $x.Id -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $cim = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $x.Id) -ErrorAction SilentlyContinue
            $path = $(if ($x.File.Name -eq 'fake-daemon.pid' -and $x.File.Directory.Name -ne 'stray') { Join-Path $x.File.DirectoryName 'v1.15.6\zccache-daemon.exe' } else { Join-Path $x.Tree 'install\bin\zccache.cmd' })
            [pscustomobject]@{ Id = $x.Id; Path = $path; CommandLine = [string]$(if ($cim) { $cim.CommandLine })
                Start = $(if ($x.File.Name -eq 'fake-client.pid') { [DateTime]::Now } else { $p.StartTime }) }
        }
    }
    function Stop-FakeClient($Pkg) {
        foreach ($x in @(Get-FakePidFile | Where-Object { $_.Tree -eq $Pkg.Tree -and $_.File.Name -eq 'fake-client.pid' })) { Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue }
    }
    function Initialize-Package($Pkg, [long]$Budget = 100MB, [switch]$SharedRoots, [int]$Timeout = 60) {
        Install-Package $Pkg
        Initialize-AapZcJob -InstallDir $Pkg.Install -JobRoot $Pkg.Job -BudgetBytes $Budget -SharedRoots:$SharedRoots -WrapperTimeoutSeconds $Timeout
    }
    # Reads a file another process may still hold open (a killed client's orphan keeps inherited handles).
    function Read-Shared([string]$Path) {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    }
    # The compiler launcher Initialize-AapZcJob wrote for CMake (state\runner.env), or the same command when it wrote
    # none: the shim always starts exactly as a build would start it.
    function Get-Launcher($Pkg) {
        $f = Join-Path $Pkg.Job 'state\runner.env'
        $l = @(if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f | Where-Object { $_ -like 'CMAKE_C_COMPILER_LAUNCHER=*' } })
        if ($l.Count) { return @($l[0].Substring('CMAKE_C_COMPILER_LAUNCHER='.Length) -split ';') }
        @($script:Pwsh, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Pkg.Install 'zcshim.ps1'))
    }
    function Start-Shim($Pkg, [string[]]$Argv, [string]$Out, [string]$Err) {
        $l = @(Get-Launcher $Pkg)
        $a = @{ FilePath = $l[0]; ArgumentList = ((@($l | Select-Object -Skip 1) + $Argv | ForEach-Object { ConvertTo-AapZcArg $_ }) -join ' '); NoNewWindow = $true; PassThru = $true }
        if ($Out) { $a.RedirectStandardOutput = $Out; $a.RedirectStandardError = $Err }
        $p = Start-Process @a
        $null = $p.Handle  # Windows PowerShell 5.1 reports no ExitCode unless the handle was opened while running
        $p
    }
    function Invoke-Shim($Pkg, [string[]]$Argv, [hashtable]$Env = @{}, [switch]$NoState) {
        $saved = @{}
        $Env['AAP_ZC_STATE'] = $(if ($NoState) { $null } else { $Pkg.Config })
        foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
        $o = New-TempName; $e = New-TempName
        try {
            # Only the shim itself is awaited: a killed client's orphan may outlive it.
            $p = Start-Shim $Pkg $Argv $o $e
            $p.WaitForExit()
            [pscustomobject]@{ Code = $p.ExitCode; Out = Read-Shared $o; Err = Read-Shared $e }
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
            namespace = [ordered]@{ repository_id = 4242; repository = 'org/repo'; trust_class = $Class; platform = 'windows-x86_64'; toolchain_digest = $Digest; zccache_version = '1.15.6' } }
    }
    function New-Mount($Pkg, $Binding, [string]$MarkerClass, [string]$MarkerVersion) {
        $m = Join-Path $Pkg.Tree ('mount-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $m
        $ns = [ordered]@{}
        foreach ($k in $Binding.namespace.Keys) { $ns[$k] = $Binding.namespace[$k] }
        if ($MarkerClass) { $ns.trust_class = $MarkerClass }
        if ($MarkerVersion) { $ns.zccache_version = $MarkerVersion }
        Write-Json ([ordered]@{ schema = 1; root_id = $Binding.root_id; namespace = $ns }) (Join-Path $m 'aap-cache-root.json')
        return $m
    }
    function Connect-Binding($Pkg, $Binding, [string]$Mount, [string]$Runner = 'aap-w-1-7-0011aabb') {
        $bp = Join-Path $Pkg.Tree ('binding-' + [guid]::NewGuid().ToString('N') + '.json')
        if ($null -ne $Binding) { if ($Binding -is [string]) { [IO.File]::WriteAllText($bp, $Binding) } else { Write-Json $Binding $bp } }
        Connect-AapZcSharedRoot -InstallDir $Pkg.Install -JobRoot $Pkg.Job -BindingPath $bp -MountPath $Mount -RunnerName $Runner
    }
}

AfterAll {
    if ($env:AAP_ZC_KEEP) { return }
    foreach ($x in @(Get-FakePidFile)) { Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue }
    $deadline = [DateTime]::Now.AddSeconds(30)
    do {
        $left = @(Get-RunProcess)
        foreach ($x in $left) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:RunRoot -Recurse -Force -ErrorAction SilentlyContinue
        $done = -not $left.Count -and -not (Test-Path -LiteralPath $script:RunRoot)
        if (-not $done) { Start-Sleep -Milliseconds 250 }
    } until ($done -or [DateTime]::Now -gt $deadline)
    # The suite's own hygiene check: hosted runners are thrown away, a developer's machine is not.
    $left = @(Get-RunProcess)
    if ($left.Count -or (Test-Path -LiteralPath $script:RunRoot)) {
        throw ('the run left {0} or processes {1} behind' -f $script:RunRoot, (($left | ForEach-Object { $_.ProcessId }) -join ','))
    }
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
    BeforeAll { Mock Get-AapZcProcessList -ModuleName AapZcCache { Get-FakeProcessList } }

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
        $cfg.roots.private.daemon.pid | Should -Be ([int](Get-Content -LiteralPath (Join-Path $pkg.Job 'roots\private\fake-daemon.pid')))
        $cfg.shared_roots | Should -BeFalse -Because 'shared roots stay off until the lab proof exists'
        $cfg.wrapper_timeout_seconds | Should -Be 60
        $cfg.wrapper_timeout_long_seconds | Should -Be 600
        $cfg.zccache_version | Should -Be '1.15.6'
        $envText = [IO.File]::ReadAllText((Join-Path $pkg.Job 'state\runner.env'))
        $envText | Should -Match ('AAP_ZC_STATE=' + [regex]::Escape($pkg.Config))
        $envText | Should -Match 'CMAKE_C_COMPILER_LAUNCHER=[^;]*\\pwsh\.exe;.*;-File;.*zcshim\.ps1'
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
    It 'wires nothing and starts no daemon when PowerShell 7 is missing for the launcher' {
        $pkg = New-Package
        $mod = Get-Module AapZcCache
        $saved = & $mod { $script:LauncherShell }
        & $mod { $script:LauncherShell = 'C:\nonexistent\pwsh.exe' }
        try { $cfg = Initialize-Package $pkg } finally { & $mod { param($v) $script:LauncherShell = $v } $saved }
        $cfg.state | Should -Be 'direct'
        $cfg.detail | Should -Match 'PowerShell 7'
        [IO.File]::ReadAllText((Join-Path $pkg.Job 'state\runner.env')) | Should -BeExactly ''
        Test-Path (Join-Path $pkg.Job 'roots\private\fake-daemon.pid') | Should -BeFalse
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
        Mock Get-AapZcProcessList -ModuleName AapZcCache { Get-FakeProcessList }
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
        $r = Compile $script:Pkg 'a.c' @{ ACTIONS_RUNTIME_TOKEN = 'synthetic-p13'; DATABASE_URL = 'postgres://a:synthetic@db/x'; ZCCACHE_MODE = 'LINK'; ZCCACHE_ENDPOINT = 'x'; ZCCACHE_PATH_REMAP = 'auto' }
        $r.Code | Should -Be 0
        $last = @(Get-Content -LiteralPath (Join-Path $script:Pkg.Job 'roots\private\fake-env.log'))[-1]
        $last | Should -Not -Match '\bACTIONS_RUNTIME_TOKEN\b|\bDATABASE_URL\b|\bZCCACHE_ENDPOINT\b|\bZCCACHE_PATH_REMAP\b'
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
                $proc = Start-Shim $script:Pkg @($script:Pkg.Cc, '-c', (Join-Path $script:Pkg.Src 'a.c'), '-o', $out)
                $runs += [pscustomobject]@{ Out = $out; P = $proc }
            }
            foreach ($r in $runs) { $r.P.WaitForExit() }
        } finally { $env:AAP_ZC_STATE = $saved }
        foreach ($r in $runs) { $r.P.ExitCode | Should -Be 0; [IO.File]::ReadAllBytes($r.Out) | Should -Be $script:Expected }
        $log = Get-Content -LiteralPath (Join-Path $script:Pkg.Job 'shim\shim.log')
        @($log | Where-Object { $_ -notmatch '^\d{4}-\d\d-\d\dT[\d:.]+Z (zccache|direct|fallback) ' }).Count | Should -Be 0
    }
}

Describe 'zcshim.ps1: arguments reach zccache and the compiler unchanged (the real launcher)' {
    BeforeAll {
        Mock Get-AapZcProcessList -ModuleName AapZcCache { Get-FakeProcessList }
        $q = @(foreach ($c in 'compile-object', 'path-with-spaces', 'response-file') {
                [ordered]@{ compiler = 'clang'; compiler_version = '18.1.3'; invocation = $c; evidence_ref = 'parity/cache/qualification/evidence/x.json' } })
        $script:Pkg = New-Package -Qualified $q
        $null = Initialize-Package $script:Pkg
        $rsp = Join-Path $script:Pkg.Tree 'args file.rsp'
        [IO.File]::WriteAllText($rsp, '-c "src dir\a.c"')
        $script:Tricky = @('-c', (Join-Path $script:Pkg.Src 'a.c'), '-std:c++17', '-x:y', '-Fo:C:\x y\a.obj', '--%', '-a:',
            'ünï中', 'a"b', 'q "x" y', '', 'C:\out dir\', 'a\\"b', ('@' + $rsp), '-o', (Join-Path $script:Pkg.Tree 'out dir.o'))
        # NUL-joined, so empty and quoted arguments compare exactly in both editions.
        function Get-Argv([string]$Path) { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json; @(foreach ($a in $j) { [string]$a }) -join [char]0 }
        function Format-Argv([string[]]$Argv) { $Argv -join [char]0 }
    }

    It 'zccache receives the compiler and every argument exactly' {
        $log = Join-Path $script:Pkg.Tree 'argv-zccache.json'
        $r = Invoke-Shim $script:Pkg (@($script:Pkg.Cc) + $script:Tricky) @{ FAKE_ZC_ARGV_LOG = $log }
        $r.Code | Should -Be 0
        Get-Argv $log | Should -BeExactly (Format-Argv (@($script:Pkg.Cc) + $script:Tricky))
        Get-Flag $script:Pkg | Should -BeNullOrEmpty -Because 'the call went through zccache, not the fallback'
    }
    It 'a compiler run directly receives every argument exactly, a leading bare - included' {
        $log = Join-Path $script:Pkg.Tree 'argv-direct.json'
        $notToolchain = Join-Path $script:Pkg.Install 'bin\zccache.cmd'
        $r = Invoke-Shim $script:Pkg (@($notToolchain, '-') + $script:Tricky) @{ FAKE_ZC_ARGV_LOG = $log }
        $r.Code | Should -Be 0
        Get-Argv $log | Should -BeExactly (Format-Argv (@('-') + $script:Tricky))
    }
}

Describe 'zcshim: faults' {
    BeforeAll { Mock Get-AapZcProcessList -ModuleName AapZcCache { Get-FakeProcessList } }
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
    It 'over budget in total (artifacts past the whole budget) also stops using the root' -Tag 'WIN-OVER-BUDGET' {
        $pkg = New-Package
        $null = Initialize-Package $pkg 4MB
        $cfg = Get-Content -Raw $pkg.Config | ConvertFrom-Json
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $cfg.roots.private.dir 'artifacts')
        [IO.File]::WriteAllBytes((Join-Path $cfg.roots.private.dir 'artifacts\big'), (New-Object byte[] (5MB)))
        $r = Compile $pkg
        $r.Code | Should -Be 0
        Get-Flag $pkg | Should -Be 'over-budget'
        @(Get-Journal $pkg).Count | Should -Be 0
    }
    It 'a hung zccache call is killed at the bound with everything it started, and the compiler runs directly' -Tag 'WIN-SHIM-TIMEOUT', 'WIN-KILL-TREE', 'WIN-TIMEOUT-DAEMON' {
        $pkg = New-Package
        $cfg = Initialize-Package $pkg -Timeout 2
        $expected = Get-Direct $pkg (Join-Path $pkg.Src 'a.c')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # The hung client leaves a child that writes the output 8 s in, after the direct compile.
        try { $r = Compile $pkg 'a.c' @{ FAKE_ZC_HANG = '30'; FAKE_ZC_LATE = '8' } } finally { $took = $sw.Elapsed.TotalSeconds; Stop-FakeClient $pkg }
        $took | Should -BeLessThan 15
        while ($sw.Elapsed.TotalSeconds -lt 14) { Start-Sleep -Milliseconds 250 }
        $r.Code | Should -Be 0
        [IO.File]::ReadAllBytes($r.Output) | Should -Be $expected -Because 'nothing the wrapped call started may write the output late'
        Get-Flag $pkg | Should -Be 'wrapper-timeout'
        Get-Process -Id $cfg.roots.private.daemon.pid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the daemon may still be compiling that output'
    }
    It 'bounds an object compile by the short timeout and every other call by the long one' -Tag 'WIN-TIMEOUT-CLASS' {
        $c = [pscustomobject]@{ wrapper_timeout_seconds = 60; wrapper_timeout_long_seconds = 600 }
        InModuleScope AapZcCache -Parameters @{ C = $c } {
            Get-AapZcWrapperTimeout $C @('compile-object', 'depfile') | Should -Be 60
            Get-AapZcWrapperTimeout $C @('rustc-wrapper') | Should -Be 600
            Get-AapZcWrapperTimeout $C @('debug-pdb', 'link') | Should -Be 600
            Get-AapZcWrapperTimeout $C @('compile-pch') | Should -Be 600
        }
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

Describe 'zcshim: delivery (zccache''s exit 0 counts only with every declared output in place)' {
    BeforeAll {
        Mock Get-AapZcProcessList -ModuleName AapZcCache { Get-FakeProcessList }
        function Invoke-To($Pkg, [string]$Out, [hashtable]$Env = @{}, [string[]]$Extra = @()) {
            Invoke-Shim $Pkg (@($Pkg.Cc, '-c', (Join-Path $Pkg.Src 'a.c')) + $Extra + @('-o', $Out)) $Env
        }
        function Assert-DeliveryFallback($Pkg, $Result) {
            $Result.Code | Should -Be 0
            Get-Flag $Pkg | Should -Be 'delivery'
            @(Get-Content -LiteralPath (Join-Path $Pkg.Job 'shim\shim.log'))[-1] | Should -Match ' fallback fake-cc\.cmd zccache-exit 0 delivery direct-exit 0$'
            $cfg = Get-Content -Raw -LiteralPath $Pkg.Config | ConvertFrom-Json
            Get-Process -Id $cfg.roots.private.daemon.pid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the daemon may still be copying that output'
        }
        # Whether zccache's fake (run by PowerShell 7 for this) can make a symbolic link here: developer mode or elevation.
        $probe = Join-Path $script:RunRoot ('symprobe-' + [guid]::NewGuid().ToString('N'))
        & $script:Pwsh -NoProfile -NonInteractive -Command "New-Item -ItemType SymbolicLink -Path '$probe' -Value '$($script:RunRoot)' -ErrorAction Stop | Out-Null" 2>$null
        $script:CanLink = Test-Path -LiteralPath $probe
        if ($script:CanLink) { [IO.Directory]::Delete($probe) }
    }
    BeforeEach {
        $script:Pkg = New-Package
        $null = Initialize-Package $script:Pkg
        $script:Expected = Get-Direct $script:Pkg (Join-Path $script:Pkg.Src 'a.c')
    }

    It 'a miss that exits 0 without its object (<Case>) is rebuilt directly' -Tag 'WIN-OUT-CHECK', 'WIN-OUT-STALE' -TestCases @(
        @{ Case = 'nothing there before'; Stale = $false }
        @{ Case = 'a stale object there'; Stale = $true }
    ) {
        $out = Join-Path $script:Pkg.Tree 'obj.o'
        if ($Stale) { [IO.File]::WriteAllText($out, 'STALE') }
        $r = Invoke-To $script:Pkg $out @{ FAKE_CC_OMIT = 'obj' }
        [IO.File]::ReadAllBytes($out) | Should -Be $script:Expected
        Assert-DeliveryFallback $script:Pkg $r
    }
    It 'a hit that exits 0 without delivering (<Case>) is rebuilt directly' -Tag 'WIN-OUT-CHECK', 'WIN-OUT-STALE' -TestCases @(
        @{ Case = 'nothing there before'; Stale = $false }
        @{ Case = 'a stale object there'; Stale = $true }
    ) {
        $null = Compile $script:Pkg
        $out = Join-Path $script:Pkg.Tree 'hit.o'
        if ($Stale) { [IO.File]::WriteAllText($out, 'STALE') }
        $r = Invoke-To $script:Pkg $out @{ FAKE_ZC_NODELIVER = '1' }
        @(Get-Journal $script:Pkg)[-1] | Should -Be 'hit'
        [IO.File]::ReadAllBytes($out) | Should -Be $script:Expected
        Assert-DeliveryFallback $script:Pkg $r
    }
    It 'a call that exits 0 without its <Kind> depfile (<Case>) is rebuilt directly' -Tag 'WIN-OUT-CHECK', 'WIN-OUT-STALE' -TestCases @(
        @{ Kind = '-MD'; Case = 'nothing there before'; Stale = $false; Extra = @('-MD'); Dep = 'dep.d' }
        @{ Kind = '-MD'; Case = 'a stale depfile there'; Stale = $true; Extra = @('-MD'); Dep = 'dep.d' }
        @{ Kind = '-MF'; Case = 'a stale depfile there'; Stale = $true; Extra = @('-MMD', '-MF', 'MFPATH'); Dep = 'mf.dep' }
    ) {
        $dep = Join-Path $script:Pkg.Tree $Dep
        if ($Stale) { [IO.File]::WriteAllText($dep, 'STALE') }
        $r = Invoke-To $script:Pkg (Join-Path $script:Pkg.Tree 'dep.o') @{ FAKE_CC_OMIT = 'dep' } @($Extra | ForEach-Object { if ($_ -eq 'MFPATH') { $dep } else { $_ } })
        [IO.File]::ReadAllText($dep).Trim() | Should -Be 'DEP a.c'
        Assert-DeliveryFallback $script:Pkg $r
    }
    It 'a reparse point is not a delivery, whatever length it reports' -Tag 'WIN-OUT-CHECK' {
        # A symbolic link reports length 0 on both editions, so this stand-in is the only way a test reaches the
        # reparse-point test alone.
        InModuleScope AapZcCache { Test-AapZcDelivered ([pscustomobject]@{ Exists = $true; Attributes = [IO.FileAttributes]'Archive, ReparsePoint'; Length = 6 }) } | Should -BeFalse
        InModuleScope AapZcCache { Test-AapZcDelivered ([pscustomobject]@{ Exists = $true; Attributes = [IO.FileAttributes]'Archive'; Length = 6 }) } | Should -BeTrue
    }
    It 'an empty object is rebuilt directly' -Tag 'WIN-OUT-CHECK', 'WIN-OUT-DAEMON' {
        $null = Compile $script:Pkg
        $r = Compile $script:Pkg 'a.c' @{ FAKE_ZC_EMPTY = '1' }
        [IO.File]::ReadAllBytes($r.Output) | Should -Be $script:Expected
        Assert-DeliveryFallback $script:Pkg $r
    }
    It 'a symbolic link at the output path is rebuilt directly, as a regular file' -Tag 'WIN-OUT-CHECK', 'WIN-OUT-CLEAR' {
        if (-not $script:CanLink) { Set-ItResult -Skipped -Because 'no symbolic links without developer mode or elevation'; return }
        $null = Compile $script:Pkg
        $r = Compile $script:Pkg 'a.c' @{ FAKE_ZC_LINK = '1' }
        ((Get-Item -LiteralPath $r.Output -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Be 0
        [IO.File]::ReadAllBytes($r.Output) | Should -Be $script:Expected
        Assert-DeliveryFallback $script:Pkg $r
    }
    It 'a whole miss and hit with a depfile stay on zccache and replace stale files' {
        foreach ($f in 'ok.o', 'ok.d') { [IO.File]::WriteAllText((Join-Path $script:Pkg.Tree $f), 'STALE') }
        $a = Invoke-To $script:Pkg (Join-Path $script:Pkg.Tree 'ok.o') @{} @('-MD')
        $b = Invoke-To $script:Pkg (Join-Path $script:Pkg.Tree 'ok2.o') @{} @('-MD')
        $a.Code | Should -Be 0; $b.Code | Should -Be 0
        @(Get-Journal $script:Pkg) -join ',' | Should -Be 'miss,hit'
        Get-Flag $script:Pkg | Should -BeNullOrEmpty
        foreach ($n in 'ok', 'ok2') {
            [IO.File]::ReadAllBytes((Join-Path $script:Pkg.Tree ($n + '.o'))) | Should -Be $script:Expected
            [IO.File]::ReadAllText((Join-Path $script:Pkg.Tree ($n + '.d'))).Trim() | Should -Be 'DEP a.c'
        }
    }
    It 'a call whose outputs cannot be named builds directly without marking the root' -Tag 'WIN-OUT-UNKNOWN' {
        $r = Invoke-Shim $script:Pkg @($script:Pkg.Cc, '-c', (Join-Path $script:Pkg.Src 'a.c'))
        $r.Code | Should -Be 0
        $r = Invoke-Shim $script:Pkg @($script:Pkg.Cc, '-c', (Join-Path $script:Pkg.Src 'a.c'), '-o', (Join-Path $script:Pkg.Tree 'x.o'), '-o', (Join-Path $script:Pkg.Tree 'y.o'))
        @(Get-Journal $script:Pkg).Count | Should -Be 0
        @(Get-Content -LiteralPath (Join-Path $script:Pkg.Job 'shim\shim.log'))[-1] | Should -Match ' direct fake-cc\.cmd outputs-unknown exit \d+$'
        Get-Flag $script:Pkg | Should -BeNullOrEmpty
    }
    It 'passes on the compiler''s stderr without zccache''s leading progress lines' {
        $line = 'zccache[info][Q]: daemon under load: compiling, 9 compiles in flight, says the compiler'
        $r = Compile $script:Pkg 'a.c' @{ FAKE_ZC_PROGRESS = '3'; FAKE_CC_STDERR = $line }
        $r.Code | Should -Be 0
        @(Get-Journal $script:Pkg)[-1] | Should -Be 'miss'
        $r.Err.TrimEnd() | Should -BeExactly $line
    }
}

Describe 'Get-AapZcOutputs (shared vectors)' {
    It '<Name>' -Tag 'WIN-OUT-DEPFLAG' -TestCases @(
        $fx = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\outputs.json') | ConvertFrom-Json
        foreach ($v in $fx.vectors) { if ($v.platforms -contains 'windows') { @{ Name = ($v.compiler + ' ' + ($v.args -join ' ')); V = $v } } }
    ) {
        $tmp = New-Tree
        $argv = @(foreach ($a in $V.args) { if ($a -eq '@RSP') { $f = Join-Path $tmp 'args.rsp'; [IO.File]::WriteAllText($f, $V.rsp); '@' + $f } else { $a } })
        $got = Get-AapZcOutputs -Compiler $V.compiler -Arguments $argv
        if ($null -eq $V.outputs) { $got | Should -BeNullOrEmpty; ($null -eq $got) | Should -BeTrue }
        else { ($null -eq $got) | Should -BeFalse; @($got) | Should -Be @($V.outputs) }
    }
}

Describe 'Connect-AapZcSharedRoot' {
    BeforeAll { Mock Get-AapZcProcessList -ModuleName AapZcCache { Get-FakeProcessList } }
    BeforeEach {
        $script:Pkg = New-Package
        $null = Initialize-Package $script:Pkg -SharedRoots
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
        $cfg.roots.shared.daemon.pid | Should -Be ([int](Get-Content -LiteralPath (Join-Path $m 'root\fake-daemon.pid')))
        $c = Compile $script:Pkg
        $c.Code | Should -Be 0
        @(Get-Journal $script:Pkg 'private').Count | Should -Be 0
        @(Get-Content -LiteralPath (Join-Path $m 'root\fake-journal.log')).Count | Should -Be 1
    }
    It 'attaches nothing unless shared roots were turned on (off by default)' -Tag 'WIN-BIND-SWITCH' {
        $pkg = New-Package
        $null = Initialize-Package $pkg
        $b = New-Binding $pkg 'trusted'
        $m = New-Mount $pkg $b
        $r = Connect-Binding $pkg $b $m
        $r.Attached | Should -BeFalse
        $r.Reason | Should -Be 'shared-roots-off'
        Test-Path (Join-Path $m 'root') | Should -BeFalse
    }
    It 'an untrusted job never gets a shared root, <Case>' -Tag 'WIN-BIND-CLASS' -TestCases @(
        @{ Case = 'even one marked untrusted'; Class = 'untrusted'; Marker = $null }
        @{ Case = 'least of all a trusted one'; Class = 'untrusted'; Marker = 'trusted' }
        @{ Case = 'nor an unknown class'; Class = 'maybe'; Marker = $null }
    ) {
        $b = New-Binding $script:Pkg $Class
        $m = New-Mount $script:Pkg $b $Marker
        $r = Connect-Binding $script:Pkg $b $m
        $r.Attached | Should -BeFalse
        $r.Reason | Should -Be 'not-trusted'
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).active_root | Should -Be 'private'
        $null = Compile $script:Pkg
        Test-Path (Join-Path $m 'root') | Should -BeFalse -Because 'no daemon or file touched the root'
    }
    It 'a missing class means no shared root: <Case>' -Tag 'WIN-BIND-MISSING' -TestCases @(
        @{ Case = 'no binding file'; Mutate = 'none' }
        @{ Case = 'not JSON'; Mutate = 'garbage' }
        @{ Case = 'no namespace'; Mutate = 'no-namespace' }
        @{ Case = 'no trust class'; Mutate = 'no-class' }
        @{ Case = 'no zccache version'; Mutate = 'no-version' }
        @{ Case = 'empty root id'; Mutate = 'no-root-id' }
    ) {
        $b = New-Binding $script:Pkg 'trusted'
        $m = New-Mount $script:Pkg $b
        $arg = switch ($Mutate) {
            'none' { $null }
            'garbage' { '{not json' }
            'no-namespace' { $b.Remove('namespace'); $b }
            'no-class' { $b.namespace.Remove('trust_class'); $b }
            'no-version' { $b.namespace.Remove('zccache_version'); $b }
            'no-root-id' { $b.root_id = ''; $b }
        }
        $env:AAP_CACHE_TRUST_CLASS = 'trusted'
        try { $r = Connect-Binding $script:Pkg $arg $m } finally { Remove-Item Env:\AAP_CACHE_TRUST_CLASS }
        $r.Attached | Should -BeFalse
        $r.Reason | Should -Be 'binding-missing'
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).active_root | Should -Be 'private'
    }
    It 'refuses a binding for another runner' -Tag 'WIN-BIND-RUNNER' {
        $b = New-Binding $script:Pkg 'trusted' 'aap-w-2-9-ffffffff'
        $r = Connect-Binding $script:Pkg $b (New-Mount $script:Pkg $b)
        $r.Reason | Should -Be 'runner-mismatch'
    }
    It 'refuses a root made for <Case>' -Tag 'WIN-BIND-TOOLCHAIN' -TestCases @(
        @{ Case = 'other toolchains'; Field = 'toolchain_digest'; Value = ('a' * 64) }
        @{ Case = 'another zccache version'; Field = 'zccache_version'; Value = '1.15.7' }
        @{ Case = 'another platform'; Field = 'platform'; Value = 'linux-x86_64' }
    ) {
        $b = New-Binding $script:Pkg 'trusted'
        $b.namespace[$Field] = $Value
        $r = Connect-Binding $script:Pkg $b (New-Mount $script:Pkg $b)
        $r.Reason | Should -Be 'toolchain-mismatch'
    }
    It 'refuses a root whose marker names <Case>' -Tag 'WIN-BIND-MARKER' -TestCases @(
        @{ Case = 'another root id'; Kind = 'root-id' }
        @{ Case = 'the untrusted class'; Kind = 'class' }
        @{ Case = 'another zccache version'; Kind = 'version' }
    ) {
        $b = New-Binding $script:Pkg 'trusted'
        $m = switch ($Kind) {
            'root-id' { New-Mount $script:Pkg $b; $b.root_id = 'ns-ffffffffffffffff' }
            'class' { New-Mount $script:Pkg $b 'untrusted' }
            'version' { New-Mount $script:Pkg $b $null '1.0.0' }
        }
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
        $b2 = New-Binding $script:Pkg 'trusted'
        $b2.root_id = 'ns-0000000000000002'
        $r = Connect-Binding $script:Pkg $b2 (New-Mount $script:Pkg $b2)
        $r.Reason | Should -Be 'already-bound'
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).roots.shared.root_id | Should -Be 'ns-00112233aabbccdd'
    }
    It 'a wrapped compile running during the attach is never taken for the shared root''s daemon' -Tag 'WIN-DAEMON-ID' {
        $o = New-TempName; $e = New-TempName
        $env:AAP_ZC_STATE = $script:Pkg.Config; $env:FAKE_ZC_HANG = '60'
        try { $proc = Start-Shim $script:Pkg @($script:Pkg.Cc, '-c', (Join-Path $script:Pkg.Src 'a.c'), '-o', (Join-Path $script:Pkg.Tree 'hung.o')) $o $e }
        finally { Remove-Item Env:\AAP_ZC_STATE, Env:\FAKE_ZC_HANG }
        $client = Join-Path $script:Pkg.Job 'roots\private\fake-client.pid'
        for ($i = 0; $i -lt 300 -and -not (Test-Path -LiteralPath $client); $i++) { Start-Sleep -Milliseconds 100 }
        Test-Path -LiteralPath $client | Should -BeTrue -Because 'the wrapped compile is running'
        try {
            $b = New-Binding $script:Pkg 'trusted'
            $m = New-Mount $script:Pkg $b
            $r = Connect-Binding $script:Pkg $b $m
        } finally { Stop-FakeClient $script:Pkg; $null = $proc.WaitForExit(60000) }
        $r.Attached | Should -BeTrue
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).roots.shared.daemon.pid | Should -Be ([int](Get-Content -LiteralPath (Join-Path $m 'root\fake-daemon.pid')))
    }
    It 'stops every candidate and attaches nothing when the daemon is ambiguous' {
        $daemon = '"' + (Join-Path $script:Fakes 'fake-daemon.ps1') + '"'
        $stray = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $daemon) -WindowStyle Hidden -PassThru
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Pkg.Tree 'stray')
        Set-Content -LiteralPath (Join-Path $script:Pkg.Tree 'stray\fake-daemon.pid') -Value $stray.Id
        $b = New-Binding $script:Pkg 'trusted'
        $m = New-Mount $script:Pkg $b
        $r = Connect-Binding $script:Pkg $b $m
        $r.Reason | Should -Be 'daemon-start-failed'
        Start-Sleep -Milliseconds 500
        Get-Process -Id $stray.Id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Process -Id ([int](Get-Content -LiteralPath (Join-Path $m 'root\fake-daemon.pid'))) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $cfg = Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json
        $cfg.active_root | Should -Be 'private'
        $cfg.roots.PSObject.Properties.Name | Should -Not -Contain 'shared'
        @(Get-ChildItem -LiteralPath (Join-Path $script:Pkg.Job 'state') -Filter '*.tmp').Count | Should -Be 0
    }
    It 'replaces the config while a shim holds it open for reading' {
        $fs = [IO.File]::Open($script:Pkg.Config, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $b = New-Binding $script:Pkg 'trusted'
            (Connect-Binding $script:Pkg $b (New-Mount $script:Pkg $b)).Attached | Should -BeTrue
        } finally { $fs.Dispose() }
        (Get-Content -Raw $script:Pkg.Config | ConvertFrom-Json).active_root | Should -Be 'shared'
    }
    It 'refuses when nothing is qualified' {
        $pkg = New-Package -Qualified @()
        $null = Initialize-Package $pkg -SharedRoots
        $b = New-Binding $pkg 'trusted'
        (Connect-Binding $pkg $b (New-Mount $pkg $b)).Reason | Should -Be 'no-qualified-wrappers'
    }
}

Describe 'Get-AapZcState' {
    It 'reports unknown before initialization' {
        (Get-AapZcState -JobRoot (Join-Path (New-Tree) 'job')).state | Should -Be 'unknown'
    }
    It 'reports direct with byte counts when nothing is qualified' {
        Mock Get-AapZcProcessList -ModuleName AapZcCache { Get-FakeProcessList }
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
        $o = New-TempName
        try {
            $p = Start-Process -FilePath $py.Source -ArgumentList ('-I -B -c "import sys,json; print(json.dumps(sys.argv[1:]))" ' + (ConvertTo-AapZcArg $A)) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o
            $p.ExitCode | Should -Be 0
            @([IO.File]::ReadAllText($o) | ConvertFrom-Json) | Should -Be @($A)
        } finally { Remove-Item -LiteralPath $o -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-AapCacheTrustClass (contract rule 6, amended)' {
    BeforeAll {
        function New-Run([string]$Event = 'push', [string]$Branch = 'main', [int]$Repo = 1, [int]$Head = 1) {
            [pscustomobject]@{ event = $Event; head_branch = $Branch; head_sha = ('a' * 40); repository = [pscustomobject]@{ id = $Repo }; head_repository = [pscustomobject]@{ id = $Head } }
        }
        $script:Repository = [pscustomobject]@{ id = 1; full_name = 'org/repo'; default_branch = 'main' }
    }
    It '<Case> is <Want>' -Tag 'TRUST-EVENT', 'TRUST-BRANCH', 'TRUST-HEAD-REPO', 'TRUST-REACH-UNKNOWN', 'TRUST-REACHABLE' -TestCases @(
        @{ Case = 'push to the default branch'; Run = @('push', 'main', 1, 1); Reach = $true; Want = 'trusted' }
        @{ Case = 'schedule'; Run = @('schedule', 'main', 1, 1); Reach = $true; Want = 'trusted' }
        @{ Case = 'workflow_dispatch on the default branch'; Run = @('workflow_dispatch', 'main', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'pull_request'; Run = @('pull_request', 'main', 1, 2); Reach = $true; Want = 'untrusted' }
        @{ Case = 'pull_request_target on the default branch'; Run = @('pull_request_target', 'main', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'workflow_run on the default branch'; Run = @('workflow_run', 'main', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'issue_comment on the default branch'; Run = @('issue_comment', 'main', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'merge_group'; Run = @('merge_group', 'main', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'an event the rule does not name'; Run = @('repository_dispatch', 'main', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'push to dependabot/*'; Run = @('push', 'dependabot/npm/x', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'push to a branch named like the default in another case'; Run = @('push', 'Main', 1, 1); Reach = $true; Want = 'untrusted' }
        @{ Case = 'push from another head repository'; Run = @('push', 'main', 1, 2); Reach = $true; Want = 'untrusted' }
        @{ Case = 'a tag named like the default branch, already deleted, head not on the default branch'; Run = @('push', 'main', 1, 1); Reach = $false; Want = 'untrusted' }
        @{ Case = 'a push whose head was not checked against the default branch'; Run = @('push', 'main', 1, 1); Reach = $null; Want = $null }
    ) {
        $got = Get-AapCacheTrustClass -Run (New-Run @Run) -Repository $script:Repository -HeadOnDefaultBranch $Reach
        if ($null -eq $Want) { $got | Should -BeNullOrEmpty }
        else {
            $got.trust_class | Should -BeExactly $Want
            $got.repository_id | Should -Be 1
            $got.repository | Should -BeExactly 'org/repo'
        }
    }
    It 'a run of another repository yields no class' -Tag 'TRUST-SAME-REPO' {
        Get-AapCacheTrustClass -Run (New-Run 'push' 'main' 2 2) -Repository $script:Repository -HeadOnDefaultBranch $true | Should -BeNullOrEmpty
    }
    It 'an incomplete record yields no class, without throwing under strict mode' {
        Set-StrictMode -Version Latest
        Get-AapCacheTrustClass -Run $null -Repository $script:Repository -HeadOnDefaultBranch $true | Should -BeNullOrEmpty
        Get-AapCacheTrustClass -Run (New-Run) -Repository $null -HeadOnDefaultBranch $true | Should -BeNullOrEmpty
        Get-AapCacheTrustClass -Run (New-Run) -Repository ([pscustomobject]@{ id = 1; full_name = 'org/repo' }) -HeadOnDefaultBranch $true | Should -BeNullOrEmpty
        Get-AapCacheTrustClass -Run ([pscustomobject]@{ head_branch = 'main' }) -Repository $script:Repository -HeadOnDefaultBranch $true | Should -BeNullOrEmpty
        Get-AapCacheTrustClass -Run ([pscustomobject]@{ event = 'push'; head_branch = 'main'; repository = [pscustomobject]@{ id = 1 } }) -Repository $script:Repository -HeadOnDefaultBranch $true | Should -BeNullOrEmpty
        Get-AapCacheTrustClass -Run @{ event = 'push'; head_branch = 'main'; repository = @{ id = 1 }; head_repository = @{} } -Repository $script:Repository -HeadOnDefaultBranch $true | Should -BeNullOrEmpty
    }
}

Describe 'Select-AapCacheJob' {
    BeforeAll {
        function New-Job([long]$Runner, [long]$Group, [long]$Run = 9) { [pscustomobject]@{ id = $Runner * 10; run_id = $Run; runner_id = $Runner; runner_group_id = $Group } }
    }
    It 'returns the one job assigned to the runner in the pool''s group' -Tag 'TRUST-JOB-MATCH' {
        (Select-AapCacheJob -Jobs @((New-Job 7 3), (New-Job 8 3), (New-Job 7 4)) -RunnerId 7 -RunnerGroupId 3).id | Should -Be 70
    }
    It 'returns nothing for <Case>' -Tag 'TRUST-JOB-MATCH' -TestCases @(
        @{ Case = 'no match'; Jobs = @(@{ runner_id = 8; runner_group_id = 3 }) }
        @{ Case = 'the runner in another group'; Jobs = @(@{ runner_id = 7; runner_group_id = 4 }) }
        @{ Case = 'two matches'; Jobs = @(@{ id = 1; runner_id = 7; runner_group_id = 3 }, @{ id = 2; runner_id = 7; runner_group_id = 3 }) }
        @{ Case = 'no jobs'; Jobs = @() }
    ) {
        Select-AapCacheJob -Jobs $Jobs -RunnerId 7 -RunnerGroupId 3 | Should -BeNullOrEmpty
    }
}
