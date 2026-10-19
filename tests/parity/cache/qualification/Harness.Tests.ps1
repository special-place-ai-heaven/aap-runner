# P04 Windows qualification harness: lab gate, argument and banner checks, command table, journal,
# environment hygiene, cache corruption, daemon bookkeeping and the shared record.jq verdict.
# Nothing here runs zccache or a compiler. Needs jq on PATH. Pester 5, Windows PowerShell 5.1 and 7.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $script:Harness = Join-Path $script:Repo 'parity\cache\qualification\harness\qualify.ps1'
    . $script:Harness
    $script:Shell = (Get-Process -Id $PID).Path
    $script:Jq = @(Get-Command jq -CommandType Application -ErrorAction Stop)[0].Source
    $script:Tmp = [IO.Path]::GetTempPath()
    $script:Matrix = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'parity\cache\qualification\windows-x86_64.json') | ConvertFrom-Json
    $script:Ref = 'parity/cache/qualification/evidence/windows-x86_64/clang-cl-20.1.8-compile-object.json'

    function New-TempDir {
        $d = Join-Path $script:Tmp ('p04-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d
        $d
    }
    function Invoke-Harness([string[]]$Argv, [string]$Lab) {
        $prev = $env:AAP_ZCCACHE_LAB
        if ($Lab) { $env:AAP_ZCCACHE_LAB = $Lab } else { Remove-Item Env:\AAP_ZCCACHE_LAB -ErrorAction SilentlyContinue }
        $errFile = [IO.Path]::GetTempFileName(); $outFile = [IO.Path]::GetTempFileName()
        try {
            # Raw stderr: Windows PowerShell 5.1 would wrap native stderr into formatted error records.
            $argLine = (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:Harness) + $Argv | ForEach-Object { '"' + $_ + '"' }) -join ' '
            $p = Start-Process -FilePath $script:Shell -ArgumentList $argLine -NoNewWindow -Wait -PassThru -RedirectStandardError $errFile -RedirectStandardOutput $outFile
            [pscustomobject]@{ Code = $p.ExitCode; Text = [IO.File]::ReadAllText($errFile) }
        } finally {
            Remove-Item -LiteralPath $errFile, $outFile -ErrorAction SilentlyContinue
            if ($null -ne $prev) { $env:AAP_ZCCACHE_LAB = $prev } else { Remove-Item Env:\AAP_ZCCACHE_LAB -ErrorAction SilentlyContinue }
        }
    }
    function New-Journal([int]$Hit = 0, [int]$Miss = 0) { [ordered]@{ hit = $Hit; miss = $Miss; error = 0; link_hit = 0; link_miss = 0; other = 0 } }
    function New-Entry([int]$Exit, $Artifacts, $Journal) {
        $env = if ($null -ne $Journal) { @('ZCCACHE_CACHE_DIR', 'ZCCACHE_MODE', 'ZCCACHE_SESSION_ID') } else { @('ZCCACHE_MODE') }
        [ordered]@{ exit = $Exit; artifacts = $Artifacts; primary_present = ($Exit -eq 0); argv = @('x'); cache_dir = $null; zccache_env = $env; journal = $Journal }
    }
    function New-Poisoned($Artifacts) { $p = New-Entry 0 $Artifacts (New-Journal 0 1); $p.prime_exit = 0; $p.corrupted_files = 2; $p }
    # A record.jq input in which every harness check holds.
    function New-PassingInput([string]$Invocation = 'compile-object', [string]$Compiler = 'clang-cl') {
        $a = [ordered]@{ 'hello.obj' = ('a' * 64) }
        $runs = [ordered]@{ uncached = (New-Entry 0 $a $null); cold = (New-Entry 0 $a (New-Journal 0 1)); warm = (New-Entry 0 $a (New-Journal 1 0)) }
        if ($Invocation -eq 'debug-pdb') {
            $b = [ordered]@{ 'hello.obj' = ('b' * 64) }
            $runs.relocated_direct = New-Entry 0 $b $null
            $runs.relocated = New-Entry 0 $b (New-Journal 0 1)
        }
        $runs.poisoned_same_size = New-Poisoned $a
        $runs.poisoned_marker = New-Poisoned $a
        $none = [ordered]@{}
        $errs = [ordered]@{ uncached = (New-Entry 2 $none $null); cold = (New-Entry 2 $none (New-Journal 0 1)); warm = (New-Entry 2 $none (New-Journal 0 1)) }
        $meta = [ordered]@{
            platform = 'windows-x86_64'; command = 'qualify.ps1 -Compiler clang-cl'
            tool_versions = [ordered]@{ compiler = 'clang version 20.1.8'; zccache_sha256 = $ZqBinarySha256; 'zccache-fp_sha256' = $ZqFpSha256 }
            os = [ordered]@{ os_version = 'Microsoft Windows Server 2025 10.0.26100.6584'; image_os = 'win25'; image_version = '20261007.264.1' }
            env = [ordered]@{ set = [ordered]@{ ZCCACHE_MODE = 'COPY' }; removed = @() }
            daemons = @([ordered]@{ pid = 42; exe = 'C:\w\bin\zccache.exe'; in_private_bin = $true; sha256 = $ZqBinarySha256 })
            daemons_stopped = $true; crash_dumps = [ordered]@{ 'cache-ok' = 0; 'cache-error' = 0 }
            started_at = '2026-10-19T00:00:00Z'; ended_at = '2026-10-19T00:01:00Z'
            compiler = $Compiler; compiler_version = '20.1.8'; invocation = $Invocation; evidence_ref = $script:Ref
        }
        [ordered]@{ meta = $meta; runs = $runs; errors = $errs }
    }
    function Get-Record($In) { New-ZqRecord $In $script:Jq $script:Tmp | ConvertFrom-Json }
}

Describe 'Lab gate (the harness never runs on the live pool host or with credentials)' {
    It 'refuses with exit 3 when AAP_ZCCACHE_LAB is not set' {
        $r = Invoke-Harness @('-Compiler', 'cl') $null
        $r.Code | Should -Be 3
        $r.Text | Should -Match 'REFUSED: AAP_ZCCACHE_LAB=1 is not set'
    }
    It 'refuses with exit 3 when a live-install marker exists, even with AAP_ZCCACHE_LAB=1' {
        $root = New-TempDir
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'ProgramData\aap-runner')
            $r = Invoke-Harness @('-Compiler', 'cl', '-ExtraMarkerRoot', $root) '1'
            $r.Code | Should -Be 3
            $r.Text | Should -Match 'REFUSED: live aap-runner install markers present'
            $r.Text | Should -Match ([regex]::Escape((Join-Path $root 'ProgramData\aap-runner')))
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'checks the gate before any argument, so a bare call never reaches the build' {
        (Invoke-Harness @() $null).Code | Should -Be 3
    }
    It 'always probes the real install, data and WSL roots, including ProgramW6432; an extra root only adds paths' {
        $p = Get-ZqMarkerPath @('X:\fake')
        $p | Should -Contain "$env:ProgramData\aap-runner"
        $p | Should -Contain "$env:ProgramFiles\aap-runner"
        $p | Should -Contain "$env:SystemDrive\wsl"
        if ($env:ProgramW6432) { $p | Should -Contain "$env:ProgramW6432\aap-runner" }
        $p | Should -Contain 'X:\fake\ProgramData\aap-runner'
        $p | Should -Contain 'X:\fake\Program Files\aap-runner'
        $p | Should -Contain 'X:\fake\wsl'
    }
    It 'finds credential-shaped variable names and leaves ordinary ones alone' {
        $names = @('GITHUB_TOKEN', 'ACTIONS_RUNNER_INPUT_JITCONFIG', 'TYPESAFE_API_KEY', 'AGENTMEMORY_SECRET', 'DB_PASSWORD', 'AWS_SECRET_ACCESS_KEY',
            'SSH_PRIVATE_KEY', 'GH_PAT_KEY', 'Path', 'KEYBOARD_LAYOUT', 'ProgramFiles', 'INCLUDE', 'LIB', 'ImageVersion', 'PSModulePath')
        (Find-ZqSecretEnv $names) -join ',' | Should -Be 'ACTIONS_RUNNER_INPUT_JITCONFIG,AGENTMEMORY_SECRET,AWS_SECRET_ACCESS_KEY,DB_PASSWORD,GH_PAT_KEY,GITHUB_TOKEN,SSH_PRIVATE_KEY,TYPESAFE_API_KEY'
    }
    It 'Assert-ZqLab passes only with the opt-in, no marker and no credential-shaped variable' {
        $root = New-TempDir
        $prev = $env:AAP_ZCCACHE_LAB
        try {
            $candidates = @((Join-Path $root 'ProgramData\aap-runner'), (Join-Path $root 'wsl'))
            Remove-Item Env:\AAP_ZCCACHE_LAB -ErrorAction SilentlyContinue
            { Assert-ZqLab $candidates @('Path') } | Should -Throw 'REFUSED: AAP_ZCCACHE_LAB=1*'
            $env:AAP_ZCCACHE_LAB = '1'
            { Assert-ZqLab $candidates @('Path') } | Should -Not -Throw
            { Assert-ZqLab $candidates @('Path', 'GITHUB_TOKEN') } | Should -Throw 'REFUSED: credential-shaped environment variables present (names only): GITHUB_TOKEN*'
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'wsl')
            { Assert-ZqLab $candidates @('Path') } | Should -Throw 'REFUSED: live aap-runner install markers present*'
        } finally {
            if ($null -ne $prev) { $env:AAP_ZCCACHE_LAB = $prev } else { Remove-Item Env:\AAP_ZCCACHE_LAB -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Describe 'Argument and banner checks' {
    BeforeAll {
        $script:Ok = @{ Compiler = 'clang-cl'; CompilerPath = $script:Harness; CompilerVersion = '20.1.8'; Invocation = 'compile-object'
            Zccache = $script:Harness; Out = 'out.json'; EvidenceRef = 'parity/cache/qualification/evidence/windows-x86_64/x.json'
            PrereqCompiler = $null; Work = (Join-Path $script:Tmp ('p04-new-' + [guid]::NewGuid().ToString('N'))) }
        function Test-With([hashtable]$Change) { $a = $script:Ok.Clone(); foreach ($k in $Change.Keys) { $a[$k] = $Change[$k] }; Test-ZqArg @a }
    }
    It 'accepts a complete, valid argument set' { { Test-With @{} } | Should -Not -Throw }
    It 'rejects an unknown compiler' { { Test-With @{ Compiler = 'nvcc' } } | Should -Throw 'USAGE: compiler*' }
    It 'rejects a pair with no Windows matrix row' { { Test-With @{ Compiler = 'cl'; Invocation = 'rustc-wrapper' } } | Should -Throw 'USAGE: cl has no*' }
    It 'rejects a missing compiler version' { { Test-With @{ CompilerVersion = '' } } | Should -Throw 'USAGE: -CompilerVersion*' }
    It 'rejects an evidence ref outside the qualification tree or with ..' {
        { Test-With @{ EvidenceRef = 'docs/x.json' } } | Should -Throw 'USAGE: -EvidenceRef*'
        { Test-With @{ EvidenceRef = 'parity/cache/qualification/../x.json' } } | Should -Throw 'USAGE: -EvidenceRef*'
    }
    It 'rejects a compiler or zccache path that is not a file' { { Test-With @{ Zccache = 'C:\nope\zccache.exe' } } | Should -Throw 'USAGE: *is not a file' }
    It 'rejects link rows without a prerequisite compiler' { { Test-With @{ Compiler = 'link'; Invocation = 'link' } } | Should -Throw 'USAGE: link rows need*' }
    It 'rejects a non-empty work directory and a work path that is a file' {
        $d = New-TempDir
        try {
            Set-Content -LiteralPath (Join-Path $d 'f') 'x'
            { Test-With @{ Work = $d } } | Should -Throw 'USAGE: -Work must name an empty or new directory'
            { Test-With @{ Work = (Join-Path $d 'f') } } | Should -Throw 'USAGE: -Work must name an empty or new directory'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    It 'rejects a work directory that is a junction' {
        $d = New-TempDir
        try {
            $target = Join-Path $d 'target'; $null = New-Item -ItemType Directory -Path $target
            $link = Join-Path $d 'link'; $null = New-Item -ItemType Junction -Path $link -Target $target
            { Test-With @{ Work = $link } } | Should -Throw 'USAGE: -Work must not be a symbolic link or junction'
        } finally { cmd /c rmdir (Join-Path $d 'link') 2>$null; Remove-Item -LiteralPath $d -Recurse -Force }
    }
    It 'accepts a non-MSVC banner that names the exact version' {
        { Test-ZqBanner 'clang-cl' '20.1.8' "clang version 20.1.8`nTarget: x86_64-pc-windows-msvc" } | Should -Not -Throw
        { Test-ZqBanner 'rustc' '1.99.0' 'rustc 1.99.0 (0123abcd 2026-09-01)' } | Should -Not -Throw
    }
    It 'rejects a banner that names another version' {
        { Test-ZqBanner 'clang' '20.1.8' 'clang version 20.1.80' } | Should -Throw 'USAGE: the clang banner does not name version 20.1.8*'
        { Test-ZqBanner 'lld-link' '20.1.8' 'LLD 20.1.7' } | Should -Throw 'USAGE: the lld-link banner*'
        { Test-ZqBanner 'rustc' '1.99' 'rustc 1.99.0 (0123abcd 2026-09-01)' } | Should -Throw 'USAGE: the rustc banner*'
    }
    It 'rejects a version that is not dotted digits for non-MSVC compilers' {
        { Test-ZqBanner 'clang' 'VS 18' 'clang version 18' } | Should -Throw 'USAGE: -CompilerVersion*'
    }
    It 'does not compare the cl and link banners with the VS version string' {
        { Test-ZqBanner 'cl' 'VS 18.10.12224.181, VC.Tools.x86.x64 18.10.12020.329' 'Microsoft (R) C/C++ Optimizing Compiler Version 19.50.35717 for x64' } | Should -Not -Throw
    }
}

Describe 'Harness and matrix agree' {
    It 'covers exactly the (compiler, invocation) pairs of windows-x86_64.json' {
        $fromMatrix = @($script:Matrix.rows | ForEach-Object { "$($_.compiler)/$($_.invocation)" } | Sort-Object -Unique)
        $fromHarness = @($ZqPairs.Keys | ForEach-Object { $c = $_; $ZqPairs[$c] | ForEach-Object { "$c/$_" } } | Sort-Object -Unique)
        ($fromHarness -join ',') | Should -Be ($fromMatrix -join ',')
    }
    It 'pins the same zccache.exe hash as the matrix' { $ZqBinarySha256 | Should -Be $script:Matrix.zccache.binary_sha256 }
}

Describe 'Command table' {
    BeforeAll { $script:Rsp = Join-Path $script:Tmp ('p04-' + [guid]::NewGuid().ToString('N') + '.rsp') }
    AfterAll { Remove-Item -LiteralPath $script:Rsp -ErrorAction SilentlyContinue }
    It 'has a command for every harness pair, in both cases' {
        foreach ($c in $ZqPairs.Keys) { foreach ($i in $ZqPairs[$c]) { foreach ($case in 'ok', 'error') {
            $cmd = Get-ZqCommand $c $i 'C:\w\src' $case $script:Rsp 'C:\w\pre'
            $cmd.Args.Count | Should -BeGreaterThan 0
            $cmd.Primary | Should -Not -BeNullOrEmpty
        } } }
    }
    It 'uses the deliberate-error source in the error case' {
        (Get-ZqCommand 'cl' 'compile-object' 'C:\w\src' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\src\error.c'
        (Get-ZqCommand 'clang++' 'depfile' 'C:\w\src' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\src\error.cpp'
        (Get-ZqCommand 'rustc' 'rustc-wrapper' 'C:\w\src' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\src\error.rs'
        (Get-ZqCommand 'link' 'link' 'C:\w\src' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\pre\unresolved.obj'
    }
    It 'passes only @file for response-file rows and writes the arguments into it' {
        $cmd = Get-ZqCommand 'clang' 'response-file' 'C:\w x\src' 'ok' $script:Rsp 'C:\w\pre'
        @($cmd.Args) | Should -Be @("@$script:Rsp")
        [IO.File]::ReadAllText($script:Rsp) | Should -Be '"-c" "C:/w x/src/hello.c" "-o" "C:/w x/src/out/hello.o"'
        $null = Get-ZqCommand 'cl' 'response-file' 'C:\w\src' 'ok' $script:Rsp 'C:\w\pre'
        [IO.File]::ReadAllText($script:Rsp) | Should -Be '"/nologo" "/c" "/Brepro" "C:\w\src\hello.c" "/FoC:\w\src\out\hello.obj"'
    }
    It 'uses relative paths for debug-pdb so the relocated build can expose a stale comp_dir' {
        $cmd = Get-ZqCommand 'cl' 'debug-pdb' 'C:\w\src' 'ok' $script:Rsp 'C:\w\pre'
        $cmd.Args | Should -Contain 'hello.c'
        $cmd.Args | Should -Contain '/Foout\hello.obj'
        $cmd.Args | Should -Contain '/Fdout\hello.pdb'
        ($cmd.Args -join ' ') | Should -Not -Match 'C:\\w'
        (Get-ZqCommand 'rustc' 'debug-pdb' 'C:\w\src' 'ok' $script:Rsp 'C:\w\pre').Args | Should -Contain 'out\hello.exe'
    }
    It 'builds the cacheable rustc library for path-with-spaces and a binary only for link and debug-pdb' {
        $cmd = Get-ZqCommand 'rustc' 'path-with-spaces' 'C:\w x\src with spaces' 'ok' $script:Rsp 'C:\w\pre'
        $cmd.Primary | Should -Be 'libhello.rlib'
        $cmd.Args | Should -Contain 'C:\w x\src with spaces\lib.rs'
        $cmd.Args | Should -Contain 'C:\w x\src with spaces\out'
        (Get-ZqCommand 'rustc' 'link' 'C:\w\src' 'ok' $script:Rsp 'C:\w\pre').Primary | Should -Be 'hello.exe'
    }
    It 'asks for PCH output on compile-pch rows' {
        (Get-ZqCommand 'cl' 'compile-pch' 'C:\w\src' 'ok' $script:Rsp 'C:\w\pre').Args | Should -Contain '/Ychello.h'
        (Get-ZqCommand 'clang' 'compile-pch' 'C:\w\src' 'ok' $script:Rsp 'C:\w\pre').Primary | Should -Be 'hello.h.pch'
    }
}

Describe 'Journal, files, environment and corruption' {
    It 'counts journal outcomes with journal.jq and returns null without a journal' {
        $j = Join-Path $script:Tmp ('p04-' + [guid]::NewGuid().ToString('N') + '.jsonl')
        try {
            [IO.File]::WriteAllLines($j, @('{"outcome":"hit"}', '{"outcome":"miss"}', 'not json', '', '{"outcome":"link_hit"}', '{"outcome":"error"}', '{"x":1}'))
            $c = Get-ZqJournal $j $script:Jq
            "$($c.hit),$($c.miss),$($c.error),$($c.link_hit),$($c.link_miss),$($c.other)" | Should -Be '1,1,1,1,0,1'
        } finally { Remove-Item -LiteralPath $j }
        Get-ZqJournal 'C:\nope\missing.jsonl' $script:Jq | Should -BeNullOrEmpty
    }
    It 'hashes artifacts by relative path and never follows a junction' {
        $d = New-TempDir
        try {
            $outside = Join-Path $d 'outside'; $null = New-Item -ItemType Directory -Path $outside
            Set-Content -LiteralPath (Join-Path $outside 'secret.txt') 'x' -NoNewline
            $out = Join-Path $d 'out'; $null = New-Item -ItemType Directory -Path (Join-Path $out 'sub')
            Set-Content -LiteralPath (Join-Path $out 'sub\a.obj') 'x' -NoNewline
            $null = New-Item -ItemType Junction -Path (Join-Path $out 'link') -Target $outside
            $a = Get-ZqArtifact $out
            @($a.Keys) -join ',' | Should -Be 'sub\a.obj'
            $a['sub\a.obj'] | Should -Be '2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881'
            @(Get-ZqFiles (Join-Path $out 'link')).Count | Should -Be 0
        } finally { cmd /c rmdir (Join-Path $d 'out\link') 2>$null; Remove-Item -LiteralPath $d -Recurse -Force }
    }
    It 'returns ZCCACHE_ names as an array, also for zero or one name' {
        $saved = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ZCCACHE_*' })
        try {
            foreach ($s in $saved) { Remove-Item -LiteralPath "Env:\$($s.Name)" }
            $none = Get-ZqZccacheEnvName
            , $none | Should -BeOfType [object[]]
            $none.Count | Should -Be 0
            $env:ZCCACHE_MODE = 'COPY'
            $one = Get-ZqZccacheEnvName
            , $one | Should -BeOfType [object[]]
            $one -join ',' | Should -Be 'ZCCACHE_MODE'
        } finally {
            Remove-Item Env:\ZCCACHE_MODE -ErrorAction SilentlyContinue
            foreach ($s in $saved) { Set-Item -LiteralPath "Env:\$($s.Name)" -Value $s.Value }
        }
    }
    It 'removes every ZCCACHE_ variable from the lab shell and reports the names' {
        $saved = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ZCCACHE_*' })
        try {
            $env:ZCCACHE_ENDPOINT = 'pipe'; $env:ZCCACHE_PATH_REMAP = 'auto'; $env:AAP_ZQ_KEEP = 'y'
            $removed = Clear-ZqEnv
            $removed | Should -Contain 'ZCCACHE_ENDPOINT'
            $removed | Should -Contain 'ZCCACHE_PATH_REMAP'
            @(Get-ChildItem Env: | Where-Object { $_.Name -like 'ZCCACHE_*' }).Count | Should -Be 0
            $env:AAP_ZQ_KEEP | Should -Be 'y'
            $again = Clear-ZqEnv
            $again.Count | Should -Be 0
        } finally {
            Remove-Item Env:\AAP_ZQ_KEEP, Env:\ZCCACHE_ENDPOINT, Env:\ZCCACHE_PATH_REMAP -ErrorAction SilentlyContinue
            foreach ($s in $saved) { Set-Item -LiteralPath "Env:\$($s.Name)" -Value $s.Value }
        }
    }
    It 'same-size corruption flips one byte mid-file in place, keeping length, mtime and read-only state' {
        $d = New-TempDir
        try {
            $store = Join-Path $d 'artifacts'
            $null = New-Item -ItemType Directory -Path (Join-Path $store 'sub')
            $f1 = Join-Path $store 'a.bin'; [IO.File]::WriteAllBytes($f1, [byte[]](0, 1, 255))
            $old = [datetime]::SpecifyKind([datetime]'2026-01-02T03:04:05', 'Utc')
            [IO.File]::SetLastWriteTimeUtc($f1, $old)
            (Get-Item -LiteralPath $f1).IsReadOnly = $true
            $f2 = Join-Path $store 'sub\b.bin'; [IO.File]::WriteAllBytes($f2, [byte[]](7))
            $empty = Join-Path $store 'empty.bin'; [IO.File]::WriteAllBytes($empty, [byte[]]@())
            $outside = Join-Path $d 'outside'; $null = New-Item -ItemType Directory -Path $outside
            $victim = Join-Path $outside 'v.bin'; [IO.File]::WriteAllBytes($victim, [byte[]](9, 9))
            $null = New-Item -ItemType Junction -Path (Join-Path $store 'link') -Target $outside

            Invoke-ZqCorrupt $store -SameSize | Should -Be 2
            ([IO.File]::ReadAllBytes($f1) -join ',') | Should -Be '0,254,255'
            ([IO.File]::ReadAllBytes($f2) -join ',') | Should -Be '248'
            (Get-Item -LiteralPath $f1).LastWriteTimeUtc | Should -Be $old
            (Get-Item -LiteralPath $f1).Length | Should -Be 3
            (Get-Item -LiteralPath $f1).IsReadOnly | Should -BeTrue
            (Get-Item -LiteralPath $empty).Length | Should -Be 0
            ([IO.File]::ReadAllBytes($victim) -join ',') | Should -Be '9,9'

            Invoke-ZqCorrupt $store | Should -Be 3
            [IO.File]::ReadAllText($f1) | Should -Be 'P04-POISON'
            (Get-Item -LiteralPath $f1).IsReadOnly | Should -BeTrue
            ([IO.File]::ReadAllBytes($victim) -join ',') | Should -Be '9,9'
            Invoke-ZqCorrupt (Join-Path $d 'missing') | Should -Be 0
        } finally { cmd /c rmdir (Join-Path $d 'artifacts\link') 2>$null; Remove-Item -LiteralPath $d -Recurse -Force }
    }
    It 'reports the operating system and image identity as printable text' {
        $os = Get-ZqOs
        $os.os_version | Should -Match '^[ -~]{1,120}$'
        @($os.Keys) -join ',' | Should -Be 'os_version,image_os,image_version'
    }
    It 'sees no daemon and stops nothing for a private directory that runs nothing' {
        $bin = Join-Path $script:Tmp ('p04-bin-' + [guid]::NewGuid().ToString('N'))
        @(Get-ZqDaemon $bin | Where-Object { $_.in_private_bin }).Count | Should -Be 0
        Stop-ZqDaemon $bin | Should -BeTrue
    }
}

Describe 'Verdict (record.jq): the harness never emits qualified' {
    It 'passes every check and still leaves the row direct, pending lab steps 7-9' {
        $r = Get-Record (New-PassingInput)
        $r.harness_pass | Should -BeTrue
        @($r.checks.PSObject.Properties | Where-Object { $_.Value -ne $true }).Count | Should -Be 0
        @($r.checks.PSObject.Properties.Name) -join ',' | Should -Be ('ok_exit_zero,ok_runs_produce_primary,exit_codes_equal,artifacts_equal,cold_has_no_hits,warm_has_hits,' +
            'errors_stay_errors,poisoned_same_size_rejected,poisoned_marker_rejected,zccache_env_clean,daemons_pinned,no_crash_dumps,compiler_version_observed')
        $r.row.mode | Should -Be 'direct'
        $r.row.reason | Should -Be 'harness checks pass; lab steps 7-9 pending'
        $r.row.evidence_ref | Should -Be $script:Ref
        @($r.lab_gates.PSObject.Properties.Name) -join ',' | Should -Be 'concurrency,daemon_restart,unsupported_invocations'
        @($r.lab_gates.PSObject.Properties | Where-Object { $null -ne $_.Value }).Count | Should -Be 0
        $r.command | Should -Be 'qualify.ps1 -Compiler clang-cl'
        $r.tool_versions.compiler | Should -Be 'clang version 20.1.8'
        $r.os.image_version | Should -Be '20261007.264.1'
        $r.daemons_stopped | Should -BeTrue
    }
    It 'checks no banner for cl and link, whose matrix version is the VS version' {
        $r = Get-Record (New-PassingInput 'compile-object' 'cl')
        $r.harness_pass | Should -BeTrue
        @($r.checks.PSObject.Properties.Name) | Should -Not -Contain 'compiler_version_observed'
    }
    It 'adds the relocated comp_dir check for debug-pdb' {
        $in = New-PassingInput 'debug-pdb'
        (Get-Record $in).checks.relocated_matches_direct | Should -BeTrue
        $in.runs.relocated.artifacts = $in.runs.uncached.artifacts   # served the first tree's object
        $r = Get-Record $in
        $r.harness_pass | Should -BeFalse
        $r.row.reason | Should -Match 'relocated_matches_direct'
        $in.runs.Remove('relocated')
        (Get-Record $in).checks.relocated_matches_direct | Should -BeFalse
    }
    It 'fails when <Name>' -ForEach @(
        @{ Name = 'warm shows no hit (a green warm build is not caching evidence)'; Check = 'warm_has_hits'; Break = { param($i) $i.runs.warm.journal.hit = 0 } }
        @{ Name = 'hit counts are unavailable'; Check = 'warm_has_hits'; Break = { param($i) $i.runs.warm.journal = $null } }
        @{ Name = 'the cold build already hit'; Check = 'cold_has_no_hits'; Break = { param($i) $i.runs.cold.journal.hit = 1 } }
        @{ Name = 'a cached error exits zero'; Check = 'errors_stay_errors'; Break = { param($i) $i.errors.warm = New-Entry 0 ([ordered]@{}) $null } }
        @{ Name = 'a cached error exits with another code (e.g. an unreachable daemon)'; Check = 'errors_stay_errors'; Break = { param($i) $i.errors.cold.exit = 3 } }
        @{ Name = 'an error run leaves its artifact'; Check = 'errors_stay_errors'; Break = { param($i) $i.errors.cold.primary_present = $true } }
        @{ Name = 'the warm artifact differs'; Check = 'artifacts_equal'; Break = { param($i) $i.runs.warm.artifacts = [ordered]@{ 'hello.obj' = ('b' * 64) } } }
        @{ Name = 'the cold exit code differs'; Check = 'exit_codes_equal'; Break = { param($i) $i.runs.cold.exit = 1 } }
        @{ Name = 'two empty output directories compare equal but nothing was built'; Check = 'ok_runs_produce_primary'; Break = {
                param($i) foreach ($k in @('uncached', 'cold', 'warm')) { $i.runs[$k].artifacts = [ordered]@{}; $i.runs[$k].primary_present = $false } } }
        @{ Name = 'a same-size poisoned entry is served as a hit'; Check = 'poisoned_same_size_rejected'; Break = { param($i) $i.runs.poisoned_same_size.journal.hit = 1 } }
        @{ Name = 'a poisoned link entry is served as a link hit'; Check = 'poisoned_marker_rejected'; Break = { param($i) $i.runs.poisoned_marker.journal.link_hit = 1 } }
        @{ Name = 'a poisoned build differs from uncached'; Check = 'poisoned_marker_rejected'; Break = { param($i) $i.runs.poisoned_marker.artifacts = [ordered]@{ 'hello.obj' = ('c' * 64) } } }
        @{ Name = 'the poisoned build never looked the entry up'; Check = 'poisoned_marker_rejected'; Break = { param($i) $i.runs.poisoned_marker.journal.miss = 0 } }
        @{ Name = 'nothing in the store was corrupted'; Check = 'poisoned_same_size_rejected'; Break = { param($i) $i.runs.poisoned_same_size.corrupted_files = 0 } }
        @{ Name = 'the priming build failed'; Check = 'poisoned_same_size_rejected'; Break = { param($i) $i.runs.poisoned_same_size.prime_exit = 1 } }
        @{ Name = 'the poison step did not run'; Check = 'poisoned_marker_rejected'; Break = { param($i) $i.runs.Remove('poisoned_marker') } }
        @{ Name = 'a lab-shell ZCCACHE_ variable reached a build'; Check = 'zccache_env_clean'; Break = { param($i) $i.runs.warm.zccache_env = @('ZCCACHE_ENDPOINT', 'ZCCACHE_MODE') } }
        @{ Name = 'no daemon was observed'; Check = 'daemons_pinned'; Break = { param($i) $i.meta.daemons = @() } }
        @{ Name = 'a daemon runs from outside the private copy'; Check = 'daemons_pinned'; Break = { param($i) $i.meta.daemons[0].in_private_bin = $false } }
        @{ Name = 'a daemon runs another binary'; Check = 'daemons_pinned'; Break = { param($i) $i.meta.daemons[0].sha256 = ('0' * 64) } }
        @{ Name = 'a daemon wrote a crash dump'; Check = 'no_crash_dumps'; Break = { param($i) $i.meta.crash_dumps['cache-ok'] = 1 } }
        @{ Name = 'crash dumps were not counted'; Check = 'no_crash_dumps'; Break = { param($i) $i.meta.crash_dumps = $null } }
        @{ Name = 'the compiler banner names another version'; Check = 'compiler_version_observed'; Break = { param($i) $i.meta.tool_versions.compiler = 'clang version 20.1.80' } }
    ) {
        $in = New-PassingInput
        & $Break $in
        $r = Get-Record $in
        $r.harness_pass | Should -BeFalse
        $r.row.mode | Should -Be 'direct'
        $r.row.evidence_ref | Should -Be $script:Ref
        $r.row.reason | Should -Match $Check
        $r.checks.$Check | Should -BeFalse
    }
    It 'emits rows the cache-qualification contract accepts, pass or fail' {
        $in = New-PassingInput
        $good = Get-Record $in
        $in.runs.warm.journal.hit = 0
        $bad = Get-Record $in
        $bad.row.compiler_version = '20.1.9'  # unique (compiler, version, invocation) per contract rule 3
        $doc = [ordered]@{ schema = 1; zccache = $script:Matrix.zccache; platform = 'windows-x86_64'; matrix_revision = 1; rows = @($good.row, $bad.row) }
        $f = Join-Path $script:Tmp ('p04-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [IO.File]::WriteAllText($f, ($doc | ConvertTo-Json -Depth 6))
            $out = & python -I -B (Join-Path $script:Repo 'parity\contracts\validate.py') cache-qualification $f 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $out
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
}
