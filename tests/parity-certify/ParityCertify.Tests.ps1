#requires -Version 5.1
# Pester 5. Runs on Windows PowerShell 5.1 and pwsh 7. Needs python 3 on PATH (stdlib only).
# Negative controls for the P05 certification harness: each deliberate break must FAIL certification,
# and the documented/identical cases must PASS. The Linux probe is not executed here (real Linux only).

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Tool = Join-Path $Repo 'tools\parity-certify'
    $script:Certify = Join-Path $Tool 'certify.py'
    $script:Mutate = Join-Path $PSScriptRoot 'mutate.py'
    $script:Validate = Join-Path $Repo 'parity\contracts\validate.py'
    $script:Py = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Py) { $script:Py = (Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $Py) { throw 'python 3 is required' }
    $base = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $script:T = Join-Path $base ('parity-certify-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $T -Force | Out-Null

    $script:WinLog = Join-Path $Repo 'parity\baselines\windows-2025-vs2026-x64\sources\hosted-capture-39303666617.log'
    $script:UbuLog = Join-Path $Repo 'parity\baselines\ubuntu-24.04-x64\sources\hosted-capture-39305649952.log'
    $script:Allow = Join-Path $Tool 'allowlist.json'
    $script:Sha = ('a' * 40); $script:Wsha = ('b' * 40); $script:Act = 'actions/checkout@' + ('c' * 40)

    function script:Run {
        param([string[]]$CmdArgs)
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $o = & $Py -I @CmdArgs 2>&1 | ForEach-Object { "$_" } | Out-String; $c = $LASTEXITCODE }
        finally { $ErrorActionPreference = $old }
        [pscustomobject]@{ Code = $c; Out = $o }
    }
    function script:Cert { param([string[]]$CmdArgs) Run (@($Certify) + $CmdArgs) }
    function script:Mut { param([string]$In, [string]$Out, [string[]]$Op) $r = Run (@($Mutate, $In, $Out) + $Op); if ($r.Code -ne 0) { throw "mutate failed: $($r.Out)" } }
    function script:J { param($p) Get-Content -Raw -LiteralPath $p | ConvertFrom-Json }

    # reference inventories parsed from the two real hosted logs, with a recorded run identity
    foreach ($x in @(@('win', $WinLog, '39303666617'), @('ubu', $UbuLog, '39305649952'))) {
        $out = Join-Path $T ($x[0] + '-ref.json')
        $r = Cert @('parse-hosted-log', $x[1], '--out', $out, '--run-id', $x[2], '--source-sha', $Sha, '--workflow-sha', $Wsha, '--action-sha', $Act)
        if ($r.Code -ne 0) { throw "parse failed: $($r.Out)" }
        Set-Variable -Scope Script -Name ($x[0] + 'Ref') -Value $out
    }
    # the pinned identities (frozen baseline + run identity)
    $script:WinPin = Join-Path $T 'win-pin.json'
    $script:UbuPin = Join-Path $T 'ubu-pin.json'
    [IO.File]::WriteAllText($WinPin, (@{ image_version = '20261007.264.1'; runner_version = '2.337.0'; source_sha = $Sha; workflow_sha = $Wsha; action_shas = @($Act) } | ConvertTo-Json))
    [IO.File]::WriteAllText($UbuPin, (@{ image_version = '20261012.334.1'; runner_version = '2.337.0'; source_sha = $Sha; workflow_sha = $Wsha; action_shas = @($Act) } | ConvertTo-Json))

    # workload definitions + a clean results file (the three fixtures)
    $script:Defs = Join-Path $Tool 'workloads'
    $script:GoodRes = Join-Path $T 'good\results.json'
    $r = Cert @('run-workloads', '--defs', $Defs, '--out', $GoodRes, '--work', (Join-Path $T 'work-good'))
    if ($r.Code -ne 0) { throw "fixture workloads did not pass on this host: $($r.Out)" }

    function script:Compare-Inv {
        param($Ref, $Cand, $Pin, [switch]$NoAllow)
        $a = @('compare', '--reference', $Ref, '--candidate', $Cand, '--pin', $Pin, '--out', (Join-Path $T 'cmp.json'))
        if (-not $NoAllow) { $a += @('--allowlist', $Allow) }
        $r = Cert $a
        $r | Add-Member -NotePropertyName Diffs -NotePropertyValue @((J (Join-Path $T 'cmp.json')).inventory.differences) -PassThru
    }
    function script:Classes($r) { @($r.Diffs | ForEach-Object { $_.class }) }
    function script:Full {
        param($Ref, $Cand, $Pin, $Results, [string]$Name, [switch]$NoDefs)
        $o = Join-Path $T $Name
        $a = @('certify', '--reference', $Ref, '--candidate', $Cand, '--pin', $Pin, '--allowlist', $Allow, '--out', $o, '--head-sha', $Sha)
        if (-not $NoDefs) { $a += @('--defs', $Defs) }
        if ($Results) { $a += @('--results', $Results) }
        $r = Cert $a
        $r | Add-Member -NotePropertyName Dir -NotePropertyValue $o -PassThru
    }
}

AfterAll { if ($T -and (Test-Path $T)) { Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue } }

Describe 'Parsers: the two real hosted capture logs' {
    It 'parses the Windows log: image, runner, user, privileges' {
        $w = J $WinRef
        $w.schema | Should -Be 1
        $w.kind | Should -Be 'job-inventory'
        $w.image.label | Should -Be 'windows-2025-vs2026'
        $w.image.image_version | Should -Be '20261007.264.1'
        $w.image.runner_version | Should -Be '2.337.0'
        $w.image.image_os | Should -Be 'win25-vs2026'
        $w.image.os_name | Should -Be 'Microsoft Windows Server 2025 Datacenter'
        $w.user.name | Should -Be 'runneradmin'
        $w.user.is_admin | Should -BeTrue
        $w.user.uac_consent | Should -Be 0
        $w.infra.cloud | Should -Be 'Azure'
        $w.hardware.logical_processors | Should -Be 4
    }
    It 'parses the Windows environment, PATH order, tools and cache with defaults' {
        $w = J $WinRef
        $w.env.JAVA_HOME | Should -BeLike '*Java_Temurin-Hotspot_jdk\17.0.20-101\x64'
        $w.env.VSINSTALLDIR | Should -Be '<unset>'
        $w.path.process.Count | Should -Be 73
        $w.path.process[0] | Should -Be 'C:\Program Files\PowerShell\7'
        $w.path.machine.Count | Should -Be 69
        $w.shells.pwsh | Should -Be '7.6.6'
        $w.shells.powershell | Should -Be '5.1.26100.33438'
        $w.tools.visual_studio | Should -Be '18.10.12224.181'
        $w.command_paths.'link.exe' | Should -Be 'C:\Program Files\Git\usr\bin\link.exe'
        $w.tool_cache.versions.Python | Should -Contain '3.12.10'
        $w.tool_cache.defaults.Python | Should -Be '3.12.10'
        $w.tool_cache.defaults.go | Should -Be '1.24.13'
        $w.services.docker.status | Should -Be 'Running'
        $w.docker.client | Should -Be '29.7.2'
    }
    It 'records credential-bearing variables as presence only' {
        $w = J $WinRef
        $w.credential_env.PGPASSWORD | Should -BeTrue
        $w.credential_env.PGPASSWORD | Should -BeOfType [bool]
        (Get-Content -Raw $WinRef) | Should -Not -Match 'PGPASSWORD"\s*:\s*"'
    }
    It 'parses the Ubuntu log: image, runner, uid, limits, docker, services' {
        $u = J $UbuRef
        $u.image.label | Should -Be 'ubuntu-24.04'
        $u.image.image_version | Should -Be '20261012.334.1'
        $u.image.runner_version | Should -Be '2.337.0'
        $u.image.os_name | Should -Be 'Ubuntu 24.04.5 LTS'
        $u.user.name | Should -Be 'runner'
        $u.user.uid | Should -Be 1001
        $u.user.passwordless_sudo | Should -BeTrue
        $u.limits.nofile | Should -Be 65536
        $u.limits.sysctl.'vm.max_map_count' | Should -Be '262144'
        $u.limits.sysctl.'vm.mmap_rnd_bits' | Should -Be '<denied>'
        $u.path.process.Count | Should -Be 16
        $u.tools.gcc | Should -Be '13.3.0'
        $u.tool_cache.versions.node | Should -Contain '24.21.0'
        $u.docker.images.Count | Should -Be 6
        $u.services.docker.active | Should -Be 'active'
        $u.action_archive_cache | Should -Contain 'actions_checkout'
    }
    It 'converts the Readme inventory.json into the same shape where categories overlap' {
        $wr = Join-Path $T 'win-readme.json'
        (Cert @('parse-readme', (Join-Path $Repo 'parity\baselines\windows-2025-vs2026-x64\inventory.json'), '--out', $wr)).Code | Should -Be 0
        $j = J $wr
        $j.kind | Should -Be 'job-inventory'
        $j.source.type | Should -Be 'readme-inventory'
        $j.image.image_version | Should -Be '20261007.264.1'
        $j.tool_cache.defaults.Python | Should -Be '3.12.10'
        $j.coverage | Should -Contain 'tool_cache'
        # the Readme and the real job agree on image and cached versions (sections that overlap)
        $r = Cert @('compare', '--reference', $wr, '--candidate', $WinRef, '--sections', 'image,tool_cache')
        $r.Code | Should -Be 0
    }
}

Describe 'Compare: inventory negative controls (each must fail)' {
    It 'identical inventories pass (Windows and Ubuntu)' {
        Mut $WinRef (Join-Path $T 'c.json') 'copy'
        (Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin).Code | Should -Be 0
        Mut $UbuRef (Join-Path $T 'cu.json') 'copy'
        (Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin).Code | Should -Be 0
    }
    It 'removing a NON-default cached version fails as missing-required' {
        Mut $WinRef (Join-Path $T 'c.json') 'drop-cache', 'Python', '3.10.11'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        $d = $r.Diffs | Where-Object { $_.class -eq 'missing-required' -and $_.key -eq 'Python/3.10.11' }
        $d | Should -Not -BeNullOrEmpty
    }
    It 'removing the default cached version fails (version and default both reported)' {
        Mut $WinRef (Join-Path $T 'c.json') 'drop-cache', 'go', '1.24.13'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'missing-required'
    }
    It 'changing the default selection fails as default-mismatch' {
        Mut $WinRef (Join-Path $T 'c.json') 'set-default', 'Python', '3.11.9'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'default-mismatch'
    }
    It 'altering PATH order fails as path-order (Windows process and Ubuntu process)' {
        Mut $WinRef (Join-Path $T 'c.json') 'swap-path', 'process', '17', '19'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'path-order'
        Classes $r | Should -Not -Contain 'missing-required'
        Mut $UbuRef (Join-Path $T 'cu.json') 'swap-path', 'process', '1', '2'
        $r = Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'path-order'
    }
    It 'changing an SDK environment variable fails as env-mismatch' {
        Mut $WinRef (Join-Path $T 'c.json') 'set-env', 'ANDROID_NDK_HOME', 'C:\Android\android-sdk\ndk\28.0.0'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'env-mismatch'
    }
    It 'a tool or shell version change fails as version-mismatch' {
        Mut $WinRef (Join-Path $T 'c.json') 'set-shell', 'pwsh', '7.5.0'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'version-mismatch'
    }
    It 'a service state change fails as service-mismatch' {
        Mut $UbuRef (Join-Path $T 'cu.json') 'set-service', 'docker', 'active', 'inactive'
        $r = Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'service-mismatch'
    }
    It 'a category the candidate did not probe is missing-required, not silently skipped' {
        Mut $WinRef (Join-Path $T 'c.json') 'drop-coverage', 'tool_cache'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        ($r.Diffs | Where-Object { $_.section -eq 'coverage' -and $_.key -eq 'tool_cache' }) | Should -Not -BeNullOrEmpty
    }
    It 'a documented rig difference (allowlisted) passes and is reported as such' {
        Mut $WinRef (Join-Path $T 'c.json') 'set-infra', 'hostname', 'aapvm-win-01'
        Mut (Join-Path $T 'c.json') (Join-Path $T 'c2.json') 'set-hardware', 'memory_bytes', '34359738368'
        Mut (Join-Path $T 'c2.json') (Join-Path $T 'c3.json') 'add-env', 'ZCCACHE_DIR', 'D:\zccache'
        $r = Compare-Inv $WinRef (Join-Path $T 'c3.json') $WinPin
        $r.Code | Should -Be 0
        $doc = @($r.Diffs | Where-Object { $_.class -eq 'documented-rig-difference' })
        $doc.Count | Should -BeGreaterOrEqual 3
        ($doc | ForEach-Object { $_.reason }) | Should -Not -Contain $null
    }
    It 'the same differences WITHOUT the allowlist fail: the allowlist is the only reason it passed' {
        $r = Compare-Inv $WinRef (Join-Path $T 'c3.json') $WinPin -NoAllow
        $r.Code | Should -Be 1
        Classes $r | Should -Not -Contain 'documented-rig-difference'
    }
    It 'an allowlisted pattern never hides a non-allowlisted difference in the same run' {
        Mut (Join-Path $T 'c3.json') (Join-Path $T 'c4.json') 'drop-cache', 'Ruby', '3.2.11'
        $r = Compare-Inv $WinRef (Join-Path $T 'c4.json') $WinPin
        $r.Code | Should -Be 1
    }
}

Describe 'Identity pins: source, workflow, action and image SHAs' {
    It 'every pinned identity mismatch fails certification' {
        $cases = @(
            @('set-identity', 'source_sha', ('d' * 40)),
            @('set-identity', 'workflow_sha', ('d' * 40)),
            @('set-identity', 'action_shas', ('actions/checkout@' + ('d' * 40))),
            @('set-image', 'image_version', '20261018.275.1'),
            @('set-image', 'runner_version', '2.338.0')
        )
        foreach ($c in $cases) {
            Mut $WinRef (Join-Path $T 'c.json') $c
            $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
            $r.Code | Should -Be 1 -Because ($c -join ' ')
        }
    }
    It 'a candidate that matches the reference but not the pin still fails' {
        # both sides moved together to a different image: parity with the wrong generation is not certification
        $p = Join-Path $T 'badpin.json'
        [IO.File]::WriteAllText($p, (@{ image_version = '20261018.275.1' } | ConvertTo-Json))
        Mut $WinRef (Join-Path $T 'c.json') 'copy'
        (Compare-Inv $WinRef (Join-Path $T 'c.json') $p).Code | Should -Be 1
    }
}

Describe 'Workload runner' {
    BeforeAll {
        function script:One { param($Def, [string]$Name)
            $d = Join-Path $T ('defs-' + $Name); New-Item -ItemType Directory -Path $d -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $d 'w.json'), ($Def | ConvertTo-Json -Depth 8))
            $o = Join-Path $T ('res-' + $Name + '\results.json')
            $r = Cert @('run-workloads', '--defs', $d, '--out', $o, '--work', (Join-Path $T ('wk-' + $Name)))
            $r | Add-Member -NotePropertyName Res -NotePropertyValue ((J $o).results[0]) -PassThru
        }
    }
    It 'the three fixture workloads pass, with exit code, artifact hash and first causal error captured' {
        $res = (J $GoodRes).results
        $res.Count | Should -Be 3
        ($res | ForEach-Object { $_.status }) | Should -Not -Contain 'fail'
        $neg = $res | Where-Object { $_.id -eq 'fixture/negative-error' }
        $neg.exit_code | Should -Be 1
        $neg.observed | Should -Be 'failure'
        $neg.first_error.file | Should -Be 'src/bad.c'
        $neg.first_error.line | Should -Be 3
        $neg.status | Should -Be 'pass'
        $art = $res | Where-Object { $_.id -eq 'fixture/artifact-hash' }
        $art.artifacts[0].sha256 | Should -Be 'f192990f9950ce241723b90f9476c39041fbda7bfb0d62573e8953aa48af238a'
        $hello = $res | Where-Object { $_.id -eq 'fixture/c-hello' }
        $hello.exit_code | Should -Be 0
        $hello.variant | Should -Not -BeNullOrEmpty
    }
    It 'a green log with a nonzero exit code is forged-green and fails' {
        $r = One @{ id = 'forge/green'; expected_exit_codes = @(2); commands = @(, @('{python}', '-c', "import sys; print('BUILD SUCCESSFUL'); sys.exit(2)")) } 'forge1'
        $r.Code | Should -Be 1
        $r.Res.status | Should -Be 'forged-green'
        $r.Res.exit_code | Should -Be 2
    }
    It 'a failed log with exit code 0 is forged as well' {
        $r = One @{ id = 'forge/red'; commands = @(, @('{python}', '-c', "print('BUILD FAILED')")) } 'forge2'
        $r.Code | Should -Be 1
        $r.Res.status | Should -Be 'forged-green'
    }
    It 'an unexpected exit code fails; the expected first error must match' {
        $r = One @{ id = 'neg/wrong-exit'; expected_exit_codes = @(0); commands = @(, @('{python}', '-c', 'import sys; sys.exit(5)')) } 'wrongexit'
        $r.Code | Should -Be 1
        $r.Res.status | Should -Be 'fail'
        $r = One @{ id = 'neg/wrong-error'; expected_exit_codes = @(1); expected_first_error = @{ contains = 'something else' }
            commands = @(, @('{python}', '-c', "import sys; print('a.c:1:1: error: other', file=sys.stderr); sys.exit(1)")) } 'wrongerr'
        $r.Res.status | Should -Be 'fail'
        $r.Res.reasons -join ';' | Should -Match 'first causal error'
    }
    It 'a missing artifact or hash fails' {
        $r = One @{ id = 'art/missing'; commands = @(, @('{python}', '-c', 'pass')); artifact_globs = @('nothing.bin') } 'artmiss'
        $r.Res.status | Should -Be 'fail'
    }
}

Describe 'Certify: inventory and behaviour are separate sections' {
    It 'identical inventories + all workloads + pins pass, and the evidence records validate' {
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        $r = Full $WinRef (Join-Path $T 'cand.json') $WinPin $GoodRes 'ok1'
        $r.Code | Should -Be 0 -Because $r.Out
        $rep = J (Join-Path $r.Dir 'parity-report.json')
        $rep.verdict | Should -Be 'pass'
        $rep.inventory.status | Should -Be 'pass'
        $rep.behaviour.status | Should -Be 'pass'
        $files = @(Get-ChildItem (Join-Path $r.Dir 'evidence') -Filter *.json | ForEach-Object { $_.FullName })
        $files.Count | Should -Be 4   # one inventory record + three workloads
        $v = Run (@('-I', $Validate, 'evidence-bundle') + $files)
        $v.Code | Should -Be 0 -Because $v.Out
        $rec = J (Join-Path $r.Dir 'evidence\inventory__windows-2025-vs2026.json')
        $rec.reference_image.image_version | Should -Be '20261007.264.1'
        $rec.head_sha | Should -Be $Sha
        $rec.result | Should -Be 'pass'
        $rec.artifacts.Count | Should -Be 3
    }
    It 'skipping a workload fails certification and is recorded as skipped, never as pass' {
        $res = J $GoodRes
        $res.results = @($res.results | Where-Object { $_.id -ne 'fixture/artifact-hash' })
        $p = Join-Path $T 'skip-results.json'
        [IO.File]::WriteAllText($p, ($res | ConvertTo-Json -Depth 12))
        Copy-Item (Join-Path $T 'good') (Join-Path $T 'skip') -Recurse -Force -ErrorAction SilentlyContinue
        $r = Full $WinRef (Join-Path $T 'cand.json') $WinPin $p 'skip1'
        $r.Code | Should -Be 1
        $rep = J (Join-Path $r.Dir 'parity-report.json')
        $rep.inventory.status | Should -Be 'pass'
        $rep.behaviour.status | Should -Be 'fail'
        ($rep.behaviour.results | Where-Object { $_.id -eq 'fixture/artifact-hash' }).status | Should -Be 'skipped'
        $sk = J (Join-Path $r.Dir 'evidence\workload__fixture__artifact-hash.json')
        $sk.result | Should -Be 'skipped'
        $sk.oracle.observed | Should -Be 'skipped'
        (Run @('-I', $Validate, 'evidence-bundle', (Join-Path $r.Dir 'evidence\workload__fixture__artifact-hash.json'))).Code | Should -Be 0
    }
    It 'inventory alone cannot substitute for behaviour: no workloads means no certification' {
        $r = Full $WinRef (Join-Path $T 'cand.json') $WinPin $null 'nobeh' -NoDefs
        $r.Code | Should -Be 1
        (J (Join-Path $r.Dir 'parity-report.json')).behaviour.status | Should -Be 'missing'
    }
    It 'behaviour alone cannot substitute for inventory: a broken inventory fails with every workload green' {
        Mut $WinRef (Join-Path $T 'bad.json') 'drop-cache', 'Python', '3.10.11'
        $r = Full $WinRef (Join-Path $T 'bad.json') $WinPin $GoodRes 'noinv'
        $r.Code | Should -Be 1
        $rep = J (Join-Path $r.Dir 'parity-report.json')
        $rep.behaviour.status | Should -Be 'pass'
        $rep.inventory.status | Should -Be 'fail'
        (J (Join-Path $r.Dir 'evidence\inventory__windows-2025-vs2026.json')).result | Should -Be 'fail'
        $files = @(Get-ChildItem (Join-Path $r.Dir 'evidence') -Filter *.json | ForEach-Object { $_.FullName })
        (Run (@('-I', $Validate, 'evidence-bundle') + $files)).Code | Should -Be 0
    }
    It 'a forged-green workload result fails certification and its record is a valid non-pass' {
        $d = Join-Path $T 'defs-forgecert'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'f.json'), (@{ id = 'forge/green'; expected_exit_codes = @(2); commands = @(, @('{python}', '-c', "import sys; print('BUILD SUCCESSFUL'); sys.exit(2)")) } | ConvertTo-Json -Depth 8))
        $res = Join-Path $T 'forgecert\results.json'
        (Cert @('run-workloads', '--defs', $d, '--out', $res, '--work', (Join-Path $T 'wk-fc'))).Code | Should -Be 1
        $o = Join-Path $T 'forge-out'
        $r = Cert @('certify', '--reference', $WinRef, '--candidate', (Join-Path $T 'cand.json'), '--pin', $WinPin, '--allowlist', $Allow, '--defs', $d, '--results', $res, '--out', $o, '--head-sha', $Sha)
        $r.Code | Should -Be 1 -Because $r.Out
        $rec = J (Join-Path $o 'evidence\workload__forge__green.json')
        $rec.result | Should -Be 'fail'
        $rec.oracle.observed | Should -Be 'unknown'
    }
    It 'a mismatched source, workflow, action or image identity fails the full certification' {
        foreach ($c in @(@('set-identity', 'source_sha', ('e' * 40)), @('set-identity', 'workflow_sha', ('e' * 40)),
                @('set-identity', 'action_shas', ('actions/checkout@' + ('e' * 40))), @('set-image', 'image_version', '20261018.275.1'))) {
            Mut $WinRef (Join-Path $T 'idm.json') $c
            $r = Full $WinRef (Join-Path $T 'idm.json') $WinPin $GoodRes 'idm'
            $r.Code | Should -Be 1 -Because ($c -join ' ')
            (J (Join-Path $r.Dir 'parity-report.json')).inventory.identity.status | Should -Be 'fail'
        }
    }
    It 'evidence records carry no raw environment dump and no token-shaped field' {
        $files = @(Get-ChildItem (Join-Path $T 'ok1\evidence') -Filter *.json)
        foreach ($f in $files) {
            $txt = Get-Content -Raw $f.FullName
            $txt | Should -Not -Match '(?i)"(token|secret|password|credential)'
            $txt | Should -Not -Match 'JAVA_HOME'
        }
    }
}

Describe 'Windows probe: this host, safe mode, writes only under tmp' {
    BeforeAll {
        $script:Probe = Join-Path $Tool 'probe\windows.ps1'
        $script:PDir = Join-Path $T 'probe'
        $script:POut = Join-Path $PDir 'job-inventory.json'
        $script:Before = @(Get-ChildItem $T -Recurse -File | ForEach-Object { $_.FullName })
        $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
        $script:ProbeRun = & $exe -NoProfile -File $Probe -OutFile $POut -Safe 2>&1 | Out-String
    }
    It 'emits one parseable job-inventory.json with the fixed shape' {
        Test-Path $POut | Should -BeTrue
        $p = J $POut
        $p.kind | Should -Be 'job-inventory'
        $p.source.type | Should -Be 'probe'
        $p.user.name | Should -Be ([Environment]::UserName)
        $p.path.process.Count | Should -BeGreaterThan 0
        $p.hardware.logical_processors | Should -BeGreaterThan 0
    }
    It 'records only the allow-listed environment names and credential variables as booleans' {
        $p = J $POut
        $names = @($p.env.PSObject.Properties.Name)
        $names.Count | Should -BeLessThan 45
        $names | Should -Contain 'AGENT_TOOLSDIRECTORY'
        $names | Should -Not -Contain 'USERPROFILE'
        $names | Should -Not -Contain 'GITHUB_TOKEN'
        foreach ($v in $p.credential_env.PSObject.Properties) { $v.Value | Should -BeOfType [bool] }
        (Get-Content -Raw $POut) | Should -Not -Match 'ghp_|github_pat_|BEGIN .*PRIVATE KEY'
    }
    It 'leaves Docker unprobed in -Safe mode and says so in coverage' {
        $p = J $POut
        $p.docker.skipped | Should -BeTrue
        $p.coverage | Should -Not -Contain 'docker'
    }
    It 'comparing against the hosted reference reports the unprobed category and fails (a dev host is not the image)' {
        $r = Cert @('compare', '--reference', $WinRef, '--candidate', $POut, '--allowlist', $Allow)
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'coverage\.docker'
    }
    It 'wrote nothing outside the output directory' {
        $after = @(Get-ChildItem $T -Recurse -File | ForEach-Object { $_.FullName })
        $new = @($after | Where-Object { $Before -notcontains $_ })
        $new | Should -HaveCount 1
        $new[0] | Should -Be $POut
    }
}

Describe 'Linux probe' {
    # Git for Windows bash only: the bash on PATH may be the WSL launcher, which this suite must never start.
    BeforeAll { $script:GitBash = 'C:\Program Files\Git\bin\bash.exe' }
    It 'passes a bash syntax check (Git bash; skipped when absent)' -Skip:(-not (Test-Path 'C:\Program Files\Git\bin\bash.exe')) {
        $posix = (Join-Path $Tool 'probe\linux.sh') -replace '\\', '/'
        & $GitBash -n $posix
        $LASTEXITCODE | Should -Be 0
    }
    It 'runs and emits job-inventory.json (run on real Linux only)' -Skip:($true) {
        # Not run on this Windows host (CLAUDE.md: the bash suite needs a real Linux). On Linux:
        #   bash tools/parity-certify/probe/linux.sh --out job-inventory.json
        $true | Should -BeTrue
    }
}
