#requires -Version 5.1
# Pester 5. Runs on Windows PowerShell 5.1 and pwsh 7. Needs python 3 on PATH (stdlib only); no build toolchain.
# P17 workload definitions, oracle citations, shared helpers and the Invoke-Workloads entrypoint. The workloads
# themselves are validated on the hosted reference (parity-workloads.yml), not here.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $script:Win = Join-Path $Repo 'parity\workloads\windows'
    $script:Act = Join-Path $Repo 'parity\workloads\actions\windows'
    $script:Entry = Join-Path $Win 'Invoke-Workloads.ps1'
    $script:Base = Join-Path $Repo 'parity\baselines\windows-2025-vs2026-x64'
    $script:Py = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Py) { throw 'python 3 is required' }
    $script:Defs = foreach ($dir in (Join-Path $Win 'defs'), (Join-Path $Act 'defs')) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json') {
            [pscustomobject]@{ Dir = $dir; File = $f; D = (Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json) }
        }
    }
    $script:Oracle = Get-Content -Raw -LiteralPath (Join-Path $Win 'oracle\windows-2025-vs2026.json') | ConvertFrom-Json
    $tmpRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $script:T = Join-Path $tmpRoot ('p17-workload-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $T -Force | Out-Null

    function script:Run {
        param([string]$Exe, [string[]]$CmdArgs)
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $o = & $Exe @CmdArgs 2>&1 | ForEach-Object { "$_" } | Out-String; $c = $LASTEXITCODE }
        finally { $ErrorActionPreference = $old }
        [pscustomobject]@{ Code = $c; Out = $o }
    }
    function script:RunEntry { param([string[]]$CmdArgs) Run 'powershell.exe' (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Entry) + $CmdArgs) }
}

AfterAll { if ($T -and (Test-Path -LiteralPath $T)) { Remove-Item -LiteralPath $T -Recurse -Force } }

Describe 'workload definitions' {
    It 'load under the P05 harness (certify.load_defs)' {
        foreach ($dir in (Join-Path $Win 'defs'), (Join-Path $Act 'defs')) {
            $code = "import sys; sys.path.insert(0, sys.argv[1]); import certify; print(len(certify.load_defs(sys.argv[2])))"
            $r = Run $Py @('-B', '-I', '-c', $code, (Join-Path $Repo 'tools\parity-certify'), $dir)
            $r.Code | Should -Be 0 -Because $r.Out
        }
    }

    It 'sit in the folder of their id, named after it, and launch their own script with their own id' {
        foreach ($x in $Defs) {
            $id = $x.D.id
            $prefix = if ($x.Dir -like '*\actions\windows\defs') { 'actions/windows/' } else { 'windows/' }
            $id.StartsWith($prefix) | Should -BeTrue -Because $id
            $x.File.Name | Should -Be ($id.Substring($prefix.Length) + '.json')
            $c = @($x.D.commands)
            $c.Count | Should -Be 1
            $argv = @($c[0])
            ($argv[0..5] -join ' ') | Should -Be 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File'
            $argv[6] | Should -Match '^\{fixtures\}/\.\./\.\./\.\./\.\./parity/workloads/'
            Test-Path -LiteralPath (Join-Path $Repo ($argv[6] -replace '^\{fixtures\}/\.\./\.\./\.\./\.\./', '')) | Should -BeTrue -Because $argv[6]
            $argv[[array]::IndexOf($argv, '-Id') + 1] | Should -Be $id
            $argv[[array]::IndexOf($argv, '-Work') + 1] | Should -Be '{work}'
            $x.D.claim_success_regex | Should -Be '^workload \S+: all oracle checks met$'
            $x.D.claim_failure_regex | Should -Be '^workload \S+: \d+ oracle check\(s\) not met$'
            $x.D.PSObject.Properties['compare_artifacts'] | Should -BeNullOrEmpty -Because 'no artifact-comparison waivers'
        }
    }

    It 'pair every positive workload with a negative control that must fail with a named first error' {
        $neg = @($Defs | Where-Object { $_.D.id -like '*.neg-*' })
        $pos = @($Defs | Where-Object { $_.D.id -notlike '*.neg-*' })
        $neg.Count | Should -BeGreaterThan 20
        foreach ($n in $neg) {
            @($n.D.expected_exit_codes) | Should -Be @(1)
            $n.D.expected_first_error.contains | Should -Not -BeNullOrEmpty
            $n.D.PSObject.Properties['artifact_globs'] | Should -BeNullOrEmpty
        }
        # msvc-toolset-14.44 shares the missing-toolset control of msvc-toolset-14.29 (same script and mechanism)
        $shared = @{ 'windows/msvc-toolset-14.44' = 'windows/msvc-toolset-14.29.neg-missing-toolset' }
        foreach ($p in $pos) {
            @($p.D.expected_exit_codes) | Should -Be @(0)
            $ids = @($neg | Where-Object { $_.D.id -like ($p.D.id + '.neg-*') })
            if ($shared.ContainsKey($p.D.id)) { $ids = @($neg | Where-Object { $_.D.id -eq $shared[$p.D.id] }) }
            $ids.Count | Should -BeGreaterThan 0 -Because "$($p.D.id) needs a negative control"
        }
    }

    It 'are the definitions the stored hosted run validated (def hash, report hashes, first errors, tree manifest)' {
        $r = Run $Py @('-B', '-I', (Join-Path $PSScriptRoot 'check_hosted_run.py'), $Repo)
        $r.Code | Should -Be 0 -Because $r.Out
    }

    It 'list every definition through Invoke-Workloads -List' {
        $r = RunEntry @('-List')
        $r.Code | Should -Be 0 -Because $r.Out
        @($r.Out -split "`r?`n" | Where-Object { $_ }).Count | Should -Be @($Defs).Count
    }
}

Describe 'oracle citations' {
    BeforeAll {
        $script:Inv = Get-Content -Raw -LiteralPath (Join-Path $Base 'inventory.json') | ConvertFrom-Json
        $script:Log = (Get-Content -Raw -LiteralPath (Join-Path $Base 'sources\hosted-capture-39303666617.log')).Replace('\\', '\')
        $script:Readme = Get-Content -Raw -LiteralPath (Join-Path $Base 'README.md')
        $script:Leaves = New-Object Collections.ArrayList
        function script:Walk($o, [string]$path) {
            foreach ($p in $o.PSObject.Properties) {
                if ($p.Value -is [pscustomobject]) {
                    if ($p.Value.PSObject.Properties['src']) { [void]$Leaves.Add([pscustomobject]@{ Key = "$path$($p.Name)"; V = $p.Value.v; Src = $p.Value.src }) }
                    else { Walk $p.Value "$path$($p.Name)/" }
                }
            }
        }
        Walk $Oracle ''
        function script:Entries([string]$cat, [string]$name) {
            $c = $Inv.categories.PSObject.Properties[$cat]
            if (-not $c) { return @() }
            @($c.Value | Where-Object { -not $name -or $_.name -eq $name })
        }
        function script:Texts($e) {
            $t = @($e.name)
            if ($e.PSObject.Properties['versions']) { $t += $e.versions }
            if ($e.PSObject.Properties['attrs']) { $t += @($e.attrs.PSObject.Properties | ForEach-Object { $_.Value }) }
            $t
        }
    }

    It 'cites a known source kind for every value' {
        $Leaves.Count | Should -BeGreaterThan 60
        foreach ($l in $Leaves) { $l.Src | Should -Match '^(inventory|capture|capture-list|hosted|readme|docs|derived|provisional):' -Because $l.Key }
    }

    It 'matches the frozen inventory for every inventory citation' {
        foreach ($l in @($Leaves | Where-Object { $_.Src -like 'inventory:*' })) {
            $cat, $name = $l.Src.Substring(10).Split('|')
            if ($cat -eq 'identity') { $Inv.identity.$name.value | Should -Be $l.V; continue }
            $es = @(Entries $cat $name)
            $es.Count | Should -BeGreaterThan 0 -Because $l.Src
            $texts = @($es | ForEach-Object { Texts $_ })
            foreach ($v in @($l.V)) {
                # exact, except the .NET Framework targeting pack: MSBuild's v4.7.2 is the 4.7.2 in the component name
                $hit = if ($l.Key -eq 'netfx_targeting_pack') { @($texts | Where-Object { "$_".Contains("$v".TrimStart('v')) }) }
                       else { @($texts | Where-Object { "$_" -eq "$v" }) }
                $hit.Count | Should -BeGreaterThan 0 -Because "$($l.Key)=$v must appear under $($l.Src)"
            }
        }
    }

    It 'matches the hosted capture log for every capture citation' {
        foreach ($l in @($Leaves | Where-Object { $_.Src -like 'capture:*' })) {
            $text = $l.Src.Substring(8)
            if ($l.V -is [pscustomobject]) {
                # a service: its line in the capture shows the cited status and start type
                $Log | Should -Match ('Z ' + [regex]::Escape($text) + '\s+' + $l.V.Status + '\s+' + $l.V.StartType) -Because $l.Key
                continue
            }
            $Log.Contains($text) | Should -BeTrue -Because "$($l.Key): $text"
            $text | Should -Not -Match '\x1b|\$env:' -Because "$($l.Key) must cite an output line, not the script that printed it"
            if ($null -ne $l.V) { $text.Contains("$($l.V)") | Should -BeTrue -Because $l.Key }
            else { $text | Should -Match '=<unset>$|^shell:' -Because "$($l.Key) is absent" }
        }
        foreach ($l in @($Leaves | Where-Object { $_.Src -like 'capture-list:*' })) {
            foreach ($e in @($l.V)) { $Log | Should -Match ('(?m)Z ' + [regex]::Escape($e) + '\s*$') -Because $l.Key }
        }
    }

    It 'matches the stored hosted-run evidence for every hosted citation' {
        $hosted = @($Leaves | Where-Object { $_.Src -like 'hosted:*' })
        $hosted.Count | Should -BeGreaterThan 0
        foreach ($l in $hosted) {
            $l.Src -match '^hosted:(\d+)/([A-Za-z0-9._-]+):(.+)$' | Should -BeTrue -Because $l.Src
            $file = Join-Path $Win ("oracle\hosted-runs\{0}\{1}" -f $Matches[1], $Matches[2])
            $text = $Matches[3]
            Test-Path -LiteralPath $file | Should -BeTrue -Because $l.Src
            $body = Get-Content -Raw -LiteralPath $file
            if ($l.V -is [pscustomobject]) {
                # one evidence line per member: '<text><name> = <value>'
                foreach ($m in $l.V.PSObject.Properties) { $body.Contains("$text$($m.Name) = $($m.Value)") | Should -BeTrue -Because "$($l.Key).$($m.Name)" }
            }
            else {
                $body.Contains($text) | Should -BeTrue -Because $l.Src
                $text.Contains("$($l.V)") | Should -BeTrue -Because $l.Key
            }
        }
    }

    It 'matches the profile README for every readme citation' {
        foreach ($l in @($Leaves | Where-Object { $_.Src -like 'readme:*' })) { $Readme.Contains($l.Src.Substring(7)) | Should -BeTrue -Because $l.Key }
    }

    It 'keeps derived and provisional values to the reviewed set' {
        @($Leaves | Where-Object { $_.Src -like 'derived:*' } | ForEach-Object { $_.Key } | Sort-Object) | Should -Be @('tool_cache_arch', 'visual_studio/alt_toolsets')
        @($Leaves | Where-Object { $_.Src -like 'provisional:*' }) | Should -BeNullOrEmpty
        ($Inv.toolset_defaults.toolcache | Where-Object { $_.name -eq 'PyPy' }).arch | Should -Be $Oracle.tool_cache_arch.v.PyPy
        $names = @(Entries 'Visual Studio Enterprise 2026/Workloads, components and extensions' $null | ForEach-Object { $_.name })
        $names -contains 'Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64' | Should -BeTrue
        $names -contains 'Microsoft.VisualStudio.ComponentGroup.VC.Tools.142.x86.x64' | Should -BeTrue
    }
}

Describe 'Workload.psm1 helpers' {
    BeforeAll { Import-Module (Join-Path $Win 'Workload.psm1') -Force }
    AfterAll { Remove-Module Workload -ErrorAction SilentlyContinue }

    It 'reads machine and subsystem from a PE header' {
        $pe = Get-PeInfo (Join-Path $env:SystemRoot 'System32\cmd.exe')
        $pe.Machine | Should -Be 'x64'
        $pe.Subsystem | Should -Be 'console'
        $pe.Dll | Should -BeFalse
        (Get-PeInfo (Join-Path $env:SystemRoot 'System32\kernel32.dll')).Dll | Should -BeTrue
    }

    It 'collapses doubled separators but keeps the drive' {
        ConvertTo-PathNorm 'C:\Program Files (x86)\Windows Kits\10\\include\10.0.26100.0\\um' | Should -Be 'C:\Program Files (x86)\Windows Kits\10\include\10.0.26100.0\um'
        @(Split-PathList 'C:\a\\b;;D:\c') | Should -Be @('C:\a\b', 'D:\c')
    }

    It 'drops matching entries from a list variable (sabotage)' {
        $env:P17_TEST_LIST = 'C:\VC\lib;C:\Program Files (x86)\Windows Kits\10\lib\um\x64;C:\other'
        Remove-PathEntries 'P17_TEST_LIST' '*\Windows Kits\*'
        $env:P17_TEST_LIST | Should -Be 'C:\VC\lib;C:\other'
        Remove-Item Env:\P17_TEST_LIST
    }

    It 'normalizes the work and repository paths in log lines' {
        InModuleScope Workload {
            $script:S = @{ Work = 'C:\T\work\wl-1'; Repo = 'C:\src\repo' }
            Format-Norm 'C:\t\WORK\wl-1\a.c(1): see C:/src/repo/x' | Should -Be '<work>\a.c(1): see <repo>/x'
            $script:S = $null
        }
    }
}

Describe 'Invoke-Workloads entrypoint' {
    It 'refuses an unknown workload name' {
        $r = RunEntry @('-Name', 'windows/no-such-workload', '-OutDir', (Join-Path $T 'unknown'))
        $r.Code | Should -Not -Be 0
        $r.Out | Should -Match "no workload matches 'windows/no-such-workload'"
    }

    It 'refuses an empty selection' {
        $r = RunEntry @('-Name', ',', '-OutDir', (Join-Path $T 'empty-sel'))
        $r.Code | Should -Not -Be 0
        $r.Out | Should -Match 'no workload selected'
    }

    It 'refuses a non-empty output folder' {
        $d = Join-Path $T 'busy'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'old.txt') -Value 'x'
        $r = RunEntry @('-Name', 'windows/java.neg-no-java-home', '-OutDir', $d)
        $r.Code | Should -Not -Be 0
        $r.Out | Should -Match 'is not empty'
    }

    It 'runs a negative control end to end through certify.py, writes its record and prunes the work folder' {
        $out = Join-Path $T 'e2e'
        $r = RunEntry @('-Name', 'windows/java.neg', '-OutDir', $out)  # a prefix selects the negative control only
        $r.Code | Should -Be 0 -Because $r.Out
        @(Get-ChildItem -LiteralPath (Join-Path $out 'defs')).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $out 'work') | Should -BeFalse -Because 'build trees are pruned'
        $rec = Get-Content -Raw -LiteralPath (Join-Path $out 'workloads\windows__java.neg-no-java-home.json') | ConvertFrom-Json
        $rec.status | Should -Be 'pass'
        $rec.exit_code | Should -Be 1
        $rec.first_error.message | Should -Match 'javac.exe not found under JAVA_HOME'
        $rec.observed.sabotage | Should -Be 'no-java-home'
        $rec.oracle.expected_exit_codes | Should -Be @(1)
        (Get-Content -Raw -LiteralPath (Join-Path $out 'summary.json') | ConvertFrom-Json).pass | Should -Be 1
        Test-Path -LiteralPath (Join-Path $out 'results.json') | Should -BeTrue
        $tree = (Get-Content -Raw -LiteralPath (Join-Path $out 'summary.json') | ConvertFrom-Json).tree
        $now = (Run $Py @('-B', '-I', (Join-Path $Win 'tree_manifest.py'), $Repo)).Out | ConvertFrom-Json
        $tree.sha256 | Should -Be $now.sha256
        @($tree.files.PSObject.Properties).Count | Should -BeGreaterThan 40
    }
}

Describe 'script hygiene' {
    It 'avoids obfuscation-shaped PowerShell, WSL and visible windows, and stays ASCII' {
        $files = @(Get-ChildItem -LiteralPath $Win, $Act -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.yml' })
        $files.Count | Should -BeGreaterThan 10
        foreach ($f in $files) {
            $s = Get-Content -Raw -LiteralPath $f.FullName
            $s | Should -Not -Match '(?i)invoke-expression|\biex\b|-encodedcommand|frombase64string|securestring|tostringbstr|\[char\]\s*\d|start-process|wsl\.exe|\bwsl\s+-|\x1b' -Because $f.FullName
            [Text.Encoding]::UTF8.GetByteCount($s) | Should -Be $s.Length -Because "$($f.FullName) must be ASCII for Windows PowerShell 5.1"
        }
    }
}
