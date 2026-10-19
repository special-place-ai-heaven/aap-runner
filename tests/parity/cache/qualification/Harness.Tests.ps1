# P04 Windows qualification harness: lab gate, argument checks, command table and verdict logic.
# Nothing here runs zccache or a compiler. Pester 5, Windows PowerShell 5.1 and PowerShell 7.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $script:Harness = Join-Path $script:Repo 'parity\cache\qualification\harness\qualify.ps1'
    . $script:Harness
    $script:Shell = (Get-Process -Id $PID).Path
    $script:Matrix = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'parity\cache\qualification\windows-x86_64.json') | ConvertFrom-Json

    function New-TempDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ('p04-' + [guid]::NewGuid().ToString('N'))
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
    function New-Run([int]$Exit, $Artifacts) { [ordered]@{ exit = $Exit; artifacts = $Artifacts; primary_present = $Exit -eq 0 } }
    function New-PassingInput {
        $a = [ordered]@{ 'hello.obj' = ('a' * 64) }
        $runs = [ordered]@{ uncached = (New-Run 0 $a); cold = (New-Run 0 $a); warm = (New-Run 0 $a); poisoned = (New-Run 0 $a) }
        $errs = [ordered]@{ uncached = (New-Run 2 ([ordered]@{})); cold = (New-Run 2 ([ordered]@{})); warm = (New-Run 2 ([ordered]@{})) }
        $hits = [ordered]@{ cold = 0; warm = 1 }
        $meta = @{ zccache_sha256 = $ZqBinarySha256; observed = 'clang version 20.1.8'; started = '2026-10-19T00:00:00Z'
            compiler = 'clang-cl'; version = '20.1.8'; invocation = 'compile-object'; evidence_ref = 'parity/cache/qualification/evidence/windows-x86_64/clang-cl-20.1.8-compile-object.json' }
        @{ Meta = $meta; Runs = $runs; Errs = $errs; Hits = $hits }
    }
}

Describe 'Lab gate (the harness never runs on the live pool host)' {
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
    It 'always probes the real install, data and WSL roots; an extra root only adds paths' {
        $p = Get-ZqMarkerPath @('X:\fake')
        $p | Should -Contain "$env:ProgramData\aap-runner"
        $p | Should -Contain "$env:ProgramFiles\aap-runner"
        $p | Should -Contain "$env:SystemDrive\wsl"
        $p | Should -Contain 'X:\fake\ProgramData\aap-runner'
        $p | Should -Contain 'X:\fake\Program Files\aap-runner'
        $p | Should -Contain 'X:\fake\wsl'
    }
    It 'Assert-ZqLab passes only with the opt-in set and no marker present' {
        $root = New-TempDir
        $prev = $env:AAP_ZCCACHE_LAB
        try {
            $candidates = @((Join-Path $root 'ProgramData\aap-runner'), (Join-Path $root 'wsl'))
            Remove-Item Env:\AAP_ZCCACHE_LAB -ErrorAction SilentlyContinue
            { Assert-ZqLab $candidates } | Should -Throw 'REFUSED: AAP_ZCCACHE_LAB=1*'
            $env:AAP_ZCCACHE_LAB = '1'
            { Assert-ZqLab $candidates } | Should -Not -Throw
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'wsl')
            { Assert-ZqLab $candidates } | Should -Throw 'REFUSED: live aap-runner install markers present*'
        } finally {
            if ($null -ne $prev) { $env:AAP_ZCCACHE_LAB = $prev } else { Remove-Item Env:\AAP_ZCCACHE_LAB -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Describe 'Argument checks' {
    BeforeAll {
        $script:Ok = @{ Compiler = 'clang-cl'; CompilerPath = $script:Harness; CompilerVersion = '20.1.8'; Invocation = 'compile-object'
            Zccache = $script:Harness; Out = 'out.json'; EvidenceRef = 'parity/cache/qualification/evidence/windows-x86_64/x.json'
            PrereqCompiler = $null; Work = (Join-Path ([IO.Path]::GetTempPath()) ('p04-new-' + [guid]::NewGuid().ToString('N'))) }
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
    It 'rejects a non-empty work directory' {
        $d = New-TempDir
        try { Set-Content -LiteralPath (Join-Path $d 'f') 'x'; { Test-With @{ Work = $d } } | Should -Throw 'USAGE: -Work*' } finally { Remove-Item -LiteralPath $d -Recurse -Force }
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
    BeforeAll { $script:Rsp = Join-Path ([IO.Path]::GetTempPath()) ('p04-' + [guid]::NewGuid().ToString('N') + '.rsp') }
    AfterAll { Remove-Item -LiteralPath $script:Rsp -ErrorAction SilentlyContinue }
    It 'has a command for every harness pair, in both cases' {
        foreach ($c in $ZqPairs.Keys) { foreach ($i in $ZqPairs[$c]) { foreach ($case in 'ok', 'error') {
            $cmd = Get-ZqCommand $c $i 'C:\w\src' 'C:\w\src\out' $case $script:Rsp 'C:\w\pre'
            $cmd.Args.Count | Should -BeGreaterThan 0
            $cmd.Primary | Should -Not -BeNullOrEmpty
        } } }
    }
    It 'uses the deliberate-error source in the error case' {
        (Get-ZqCommand 'cl' 'compile-object' 'C:\w\src' 'C:\w\o' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\src\error.c'
        (Get-ZqCommand 'clang++' 'depfile' 'C:\w\src' 'C:\w\o' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\src\error.cpp'
        (Get-ZqCommand 'rustc' 'rustc-wrapper' 'C:\w\src' 'C:\w\o' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\src\error.rs'
        (Get-ZqCommand 'link' 'link' 'C:\w\src' 'C:\w\o' 'error' $script:Rsp 'C:\w\pre').Args | Should -Contain 'C:\w\pre\unresolved.obj'
    }
    It 'passes only @file for response-file rows and writes the arguments into it' {
        $cmd = Get-ZqCommand 'clang' 'response-file' 'C:\w x\src' 'C:\w x\src\out' 'ok' $script:Rsp 'C:\w\pre'
        @($cmd.Args) | Should -Be @("@$script:Rsp")
        [IO.File]::ReadAllText($script:Rsp) | Should -Be '"-c" "C:/w x/src/hello.c" "-o" "C:/w x/src/out/hello.o"'
        $cmd = Get-ZqCommand 'cl' 'response-file' 'C:\w\src' 'C:\w\o' 'ok' $script:Rsp 'C:\w\pre'
        [IO.File]::ReadAllText($script:Rsp) | Should -Match '"/c" "/Brepro" "C:\\w\\src\\hello.c" "/FoC:\\w\\o\\hello.obj"'
    }
    It 'asks for PDB and PCH outputs on the debug-pdb and compile-pch rows' {
        (Get-ZqCommand 'cl' 'debug-pdb' 'C:\w\src' 'C:\w\o' 'ok' $script:Rsp 'C:\w\pre').Args | Should -Contain '/FdC:\w\o\hello.pdb'
        (Get-ZqCommand 'cl' 'compile-pch' 'C:\w\src' 'C:\w\o' 'ok' $script:Rsp 'C:\w\pre').Args | Should -Contain '/Ychello.h'
        (Get-ZqCommand 'rustc' 'debug-pdb' 'C:\w\src' 'C:\w\o' 'ok' $script:Rsp 'C:\w\pre').Args | Should -Contain 'debuginfo=2'
    }
}

Describe 'Hits and artifacts' {
    It 'counts hit and link_hit journal outcomes and ignores the rest' {
        $j = Join-Path ([IO.Path]::GetTempPath()) ('p04-' + [guid]::NewGuid().ToString('N') + '.jsonl')
        try {
            [IO.File]::WriteAllLines($j, @('{"outcome":"hit"}', '{"outcome":"miss"}', 'not json', '', '{"outcome":"link_hit"}', '{"outcome":"error"}'))
            Get-ZqHitCount $j | Should -Be 2
        } finally { Remove-Item -LiteralPath $j }
        Get-ZqHitCount 'C:\nope\missing.jsonl' | Should -BeNullOrEmpty
    }
    It 'hashes artifacts by relative path and compares names and contents' {
        $d = New-TempDir
        try {
            Set-Content -LiteralPath (Join-Path $d 'a.obj') 'x' -NoNewline
            $a = Get-ZqArtifact $d
            @($a.Keys) | Should -Be @('a.obj')
            Test-ZqSame $a (Get-ZqArtifact $d) | Should -BeTrue
            Set-Content -LiteralPath (Join-Path $d 'a.obj') 'y' -NoNewline
            Test-ZqSame $a (Get-ZqArtifact $d) | Should -BeFalse
            Test-ZqSame $a $null | Should -BeFalse
        } finally { Remove-Item -LiteralPath $d -Recurse -Force }
    }
}

Describe 'Verdict' {
    It 'is qualified, with the evidence ref, only when every check holds' {
        $in = New-PassingInput
        $r = New-ZqRecord $in.Meta $in.Runs $in.Errs $in.Hits
        $r.row.mode | Should -Be 'qualified'
        $r.row.evidence_ref | Should -Be $in.Meta.evidence_ref
    }
    It 'is direct when <Name>' -ForEach @(
        @{ Name = 'warm shows no hit (a green warm build is not caching evidence)'; Check = 'warm_has_hits'; Break = { param($i) $i.Hits.warm = 0 } }
        @{ Name = 'hit counts are unavailable'; Check = 'warm_has_hits'; Break = { param($i) $i.Hits.warm = $null } }
        @{ Name = 'the cold build already hit'; Check = 'cold_has_no_hits'; Break = { param($i) $i.Hits.cold = 1 } }
        @{ Name = 'a cached error exits zero'; Check = 'errors_stay_errors'; Break = { param($i) $i.Errs.warm = New-Run 0 ([ordered]@{}) } }
        @{ Name = 'an error run leaves its artifact'; Check = 'errors_stay_errors'; Break = { param($i) $i.Errs.cold.primary_present = $true } }
        @{ Name = 'the warm artifact differs'; Check = 'artifacts_equal'; Break = { param($i) $i.Runs.warm = New-Run 0 ([ordered]@{ 'hello.obj' = ('b' * 64) }) } }
        @{ Name = 'the cold exit code differs'; Check = 'exit_codes_equal'; Break = { param($i) $i.Runs.cold.exit = 1 } }
        @{ Name = 'a poisoned entry was served'; Check = 'poisoned_entry_unused'; Break = { param($i) $i.Runs.poisoned = New-Run 0 ([ordered]@{ 'hello.obj' = ('c' * 64) }) } }
        @{ Name = 'the poison step could not run'; Check = 'poisoned_entry_unused'; Break = { param($i) $i.Runs.poisoned = $null } }
    ) {
        $in = New-PassingInput
        & $Break $in
        $r = New-ZqRecord $in.Meta $in.Runs $in.Errs $in.Hits
        $r.row.mode | Should -Be 'direct'
        $r.row.evidence_ref | Should -BeNullOrEmpty
        $r.row.reason | Should -Match $Check
    }
    It 'emits a row the cache-qualification contract accepts, in both verdicts' {
        $in = New-PassingInput
        $good = New-ZqRecord $in.Meta $in.Runs $in.Errs $in.Hits
        $in.Hits.warm = 0
        $bad = New-ZqRecord $in.Meta $in.Runs $in.Errs $in.Hits
        $doc = [ordered]@{ schema = 1; zccache = $script:Matrix.zccache; platform = 'windows-x86_64'; matrix_revision = 1; rows = @($good.row, $bad.row) }
        $bad.row.compiler_version = '20.1.8-other'  # unique (compiler, version, invocation) per contract rule 3
        $f = Join-Path ([IO.Path]::GetTempPath()) ('p04-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [IO.File]::WriteAllText($f, ($doc | ConvertTo-Json -Depth 6))
            $out = & python -I (Join-Path $script:Repo 'parity\contracts\validate.py') cache-qualification $f 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $out
        } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    }
}
