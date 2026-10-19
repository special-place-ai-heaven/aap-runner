#requires -Version 5.1
# Pester 5. Runs on Windows PowerShell 5.1 and pwsh 7. Needs python 3 on PATH (stdlib only).
# Negative controls for the P05 certification harness: each deliberate break must FAIL certification,
# and the documented/identical cases must PASS. The Linux probe is not executed here (real Linux only).

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Tool = Join-Path $Repo 'tools\parity-certify'
    $script:Certify = Join-Path $Tool 'certify.py'
    $script:Mutate = Join-Path $PSScriptRoot 'mutate.py'
    $script:LogFilter = Join-Path $PSScriptRoot 'logfilter.py'
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
    function script:WriteJson { param($Obj, [string]$Path) [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 12)) }

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
    WriteJson @{ image_version = '20261007.264.1'; runner_version = '2.337.0'; source_sha = $Sha; workflow_sha = $Wsha; action_shas = @($Act) } $WinPin
    WriteJson @{ image_version = '20261012.334.1'; runner_version = '2.337.0'; source_sha = $Sha; workflow_sha = $Wsha; action_shas = @($Act) } $UbuPin

    function script:PyDef {
        param([string]$Id, [string]$Code, [hashtable]$Extra = @{})
        $h = @{ id = $Id; commands = @(, @('{python}', '-c', $Code)) }
        foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
        $h
    }
    function script:NewDefs {
        param([string]$Name, [object[]]$Defs)
        $d = Join-Path $T ('defs-' + $Name)
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $i = 0
        foreach ($x in $Defs) { $i++; WriteJson $x (Join-Path $d "d$i.json") }
        $d
    }
    function script:RunWl {
        param([string]$DefsDir, [string]$Name)
        $o = Join-Path $T ('res-' + $Name + '\results.json')
        $r = Cert @('run-workloads', '--defs', $DefsDir, '--out', $o, '--work', (Join-Path $T ('wk-' + $Name)))
        $r | Add-Member -NotePropertyName ResFile -NotePropertyValue $o -PassThru
    }

    # the shipped fixtures (host dependent: gcc when present, else the echo fallback) are exercised by run-workloads only;
    # certification tests use a host independent set built from the same fixtures plus a python hello
    $script:FixDefs = Join-Path $Tool 'workloads'
    $script:FixRes = Join-Path $T 'fix\results.json'
    $r = Cert @('run-workloads', '--defs', $FixDefs, '--out', $FixRes, '--work', (Join-Path $T 'work-fix'))
    if ($r.Code -ne 0) { throw "fixture workloads did not pass on this host: $($r.Out)" }
    $script:GoodDefs = Join-Path $T 'defs-good'
    New-Item -ItemType Directory -Path $GoodDefs -Force | Out-Null
    Copy-Item (Join-Path $FixDefs 'fixture-negative-error.json') $GoodDefs
    Copy-Item (Join-Path $FixDefs 'fixture-artifact-hash.json') $GoodDefs
    WriteJson (PyDef 'fixture/py-hello' "print('hello from aap parity')") (Join-Path $GoodDefs 'fixture-py-hello.json')
    $g = RunWl $GoodDefs 'good'
    if ($g.Code -ne 0) { throw "good workloads did not pass: $($g.Out)" }
    $script:GoodRes = $g.ResFile

    function script:Compare-Inv {
        param($Ref, $Cand, $Pin, [switch]$NoAllow)
        $a = @('compare', '--reference', $Ref, '--candidate', $Cand, '--pin', $Pin, '--out', (Join-Path $T 'cmp.json'))
        if (-not $NoAllow) { $a += @('--allowlist', $Allow) }
        $r = Cert $a
        $diffs = @()
        if (Test-Path (Join-Path $T 'cmp.json')) { $diffs = @((J (Join-Path $T 'cmp.json')).inventory.differences) }
        $r | Add-Member -NotePropertyName Diffs -NotePropertyValue $diffs -PassThru
    }
    function script:Classes($r) { @($r.Diffs | ForEach-Object { $_.class }) }
    function script:Full {
        param($Ref, $Cand, $Pin, $Results, [string]$Name, [string]$DefsDir = $GoodDefs, [switch]$NoDefs, [string]$RefResults, [switch]$NoPin, [string]$CertifyPath = $Certify)
        $o = Join-Path $T $Name
        $a = @('certify', '--reference', $Ref, '--candidate', $Cand, '--allowlist', $Allow, '--out', $o, '--head-sha', $Sha)
        if (-not $NoPin) { $a += @('--pin', $Pin) }
        if (-not $NoDefs) { $a += @('--defs', $DefsDir) }
        if ($Results) { $a += @('--results', $Results) }
        if ($RefResults) { $a += @('--reference-results', $RefResults) }
        $r = Run (@($CertifyPath) + $a)
        $r | Add-Member -NotePropertyName Dir -NotePropertyValue $o -PassThru
    }
    function script:Verdict($dir) { J (Join-Path $dir 'verdict.json') }
    function script:Report($dir) { J (Join-Path $dir 'parity-report.json') }

    # code run by the process-tree workloads: a grandchild that records its pid, holds the harness's output handle and sleeps
    $script:GrandChild = @'
import os, subprocess, sys, time
subprocess.Popen([sys.executable, '-c', 'import os,time; open("gc.pid","w").write(str(os.getpid())); time.sleep(40)'], stdout=sys.stdout, stderr=sys.stderr)
for _ in range(400):
    if os.path.exists('gc.pid'):
        break
    time.sleep(0.05)
'@
    $script:RustErr = @'
import sys
print("error[E0425]: cannot find value `x` in this scope", file=sys.stderr)
print(" --> src/main.rs:2:5", file=sys.stderr)
sys.exit(1)
'@
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
    It 'a log with Services, Docker and Tool cache steps removed is refused (exit 2), not parsed to empty sections' {
        $bad = Join-Path $T 'win-nosteps.log'
        (Run @($LogFilter, $WinLog, $bad, 'drop', 'Services of interest', 'Docker state', 'Tool cache layout')).Code | Should -Be 0
        $r = Cert @('parse-hosted-log', $bad, '--out', (Join-Path $T 'nosteps.json'))
        $r.Code | Should -Be 2
        $r.Out | Should -Match "Services of interest|Docker state|Tool cache layout"
        Test-Path (Join-Path $T 'nosteps.json') | Should -BeFalse
    }
    It 'a step that exists but has no output is refused too' {
        foreach ($step in 'Services of interest', 'Docker state', 'Tool cache layout', 'PATH order', 'Allow-listed environment') {
            $bad = Join-Path $T 'win-emptystep.log'
            (Run @($LogFilter, $WinLog, $bad, 'echo-only', $step)).Code | Should -Be 0
            (Cert @('parse-hosted-log', $bad, '--out', (Join-Path $T 'emptystep.json'))).Code | Should -Be 2 -Because $step
        }
        $bad = Join-Path $T 'ubu-emptystep.log'
        (Run @($LogFilter, $UbuLog, $bad, 'echo-only', 'Services of interest')).Code | Should -Be 0
        (Cert @('parse-hosted-log', $bad, '--out', (Join-Path $T 'emptystep.json'))).Code | Should -Be 2
    }
    It 'a reference inventory whose covered section is empty is refused by compare and certify (exit 2)' {
        foreach ($op in @(@('empty-section', 'services'), @('empty-section', 'env'), @('empty-section', 'shells'), @('empty-cache'))) {
            $c = Join-Path $T 'ref-empty.json'
            Mut $WinRef $c $op
            (Cert @('compare', '--reference', $c, '--candidate', $WinRef)).Code | Should -Be 2 -Because ($op -join ' ')
        }
        Mut $WinRef (Join-Path $T 'ref-empty.json') 'empty-section', 'services'
        (Full (Join-Path $T 'ref-empty.json') $WinRef $WinPin $GoodRes 'refempty').Code | Should -Be 2
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
    It 'removing the default cached version AND its default entry reports both missing-required and default-mismatch' {
        Mut $WinRef (Join-Path $T 'c0.json') 'drop-cache', 'go', '1.24.13'
        Mut (Join-Path $T 'c0.json') (Join-Path $T 'c.json') 'drop-default', 'go'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'missing-required'
        Classes $r | Should -Contain 'default-mismatch'
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
    It 'an extra PATH entry placed ahead of a reference entry (shadowing) fails as path-order' {
        Mut $WinRef (Join-Path $T 'c.json') 'insert-path', 'process', '0', 'C:\shadow\bin'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        ($r.Diffs | Where-Object { $_.class -eq 'path-order' -and $_.candidate -eq 'C:\shadow\bin' }) | Should -Not -BeNullOrEmpty
        Mut $UbuRef (Join-Path $T 'cu.json') 'insert-path', 'machine', '3', '/opt/shadow/bin'
        (Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin).Code | Should -Be 1
    }
    It 'an extra PATH entry after the last reference entry cannot shadow anything and is only reported as extra' {
        Mut $WinRef (Join-Path $T 'c.json') 'append-path', 'process', 'C:\tail\bin'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 0
        Classes $r | Should -Contain 'extra'
    }
    It 'an allowlisted PATH entry (zccache) ahead of the reference entries is a documented rig difference' {
        Mut $WinRef (Join-Path $T 'c.json') 'insert-path', 'process', '0', 'C:\tools\zccache\bin'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 0
        Classes $r | Should -Contain 'documented-rig-difference'
    }
    It 'a command callable on the candidate but not on the reference (cl.exe) fails' {
        Mut $WinRef (Join-Path $T 'c.json') 'add-command', 'cl.exe', 'C:\VS\VC\bin\cl.exe'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        ($r.Diffs | Where-Object { $_.section -eq 'command_paths' -and $_.key -eq 'cl.exe' -and $_.class -eq 'path-order' }) | Should -Not -BeNullOrEmpty
    }
    It 'a service only the candidate has fails as service-mismatch' {
        Mut $WinRef (Join-Path $T 'c.json') 'add-service', 'Spooler', 'Running', 'Automatic'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'service-mismatch'
        Mut $UbuRef (Join-Path $T 'cu.json') 'add-service', 'cron', 'enabled', 'active'
        (Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin).Code | Should -Be 1
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
    It 'runner_environment self-hosted vs github-hosted is allowlisted (the definition of the rig difference)' {
        Mut $WinRef (Join-Path $T 'c.json') 'set-image', 'runner_environment', 'self-hosted'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 0
        ($r.Diffs | Where-Object { $_.key -eq 'runner_environment' }).class | Should -Be 'documented-rig-difference'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin -NoAllow
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'version-mismatch'
    }
    It 'the allowlist enumerates keys: no infra.* / hardware.* wildcards, and kernel/read-ahead/mount options are not in it' {
        $al = J $Allow
        $m = @($al.entries | ForEach-Object { $_.match })
        $m | Should -Not -Contain 'infra.*'
        $m | Should -Not -Contain 'hardware.*'
        $m | Should -Not -Contain 'hardware.root_disk_free_bytes'
        $m | Should -Contain 'infra.hostname'
        $m | Should -Contain 'hardware.memory_bytes'
        foreach ($k in 'image.kernel', 'limits.read_ahead_kb', 'limits.mount_options') { $m | Should -Not -Contain $k }
        @($al.floors | ForEach-Object { $_.match }) | Should -Contain 'hardware.root_disk_free_bytes'
        foreach ($e in @($al.entries) + @($al.floors)) { $e.reason | Should -Not -BeNullOrEmpty }
    }
    It 'free disk below the reference fails; above it is a documented rig difference' {
        Mut $WinRef (Join-Path $T 'c.json') 'set-hardware', 'root_disk_free_bytes', '1'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 1
        ($r.Diffs | Where-Object { $_.key -eq 'root_disk_free_bytes' }).class | Should -Be 'env-mismatch'
        Mut $WinRef (Join-Path $T 'c.json') 'set-hardware', 'root_disk_free_bytes', '99999999999999'
        $r = Compare-Inv $WinRef (Join-Path $T 'c.json') $WinPin
        $r.Code | Should -Be 0
        ($r.Diffs | Where-Object { $_.key -eq 'root_disk_free_bytes' }).class | Should -Be 'documented-rig-difference'
    }
    It 'Ubuntu kernel, read-ahead and mount options stay failing differences (not allowlisted)' {
        Mut $UbuRef (Join-Path $T 'cu.json') 'set-image', 'kernel', '6.8.0-generic'
        $r = Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin
        $r.Code | Should -Be 1
        Classes $r | Should -Contain 'version-mismatch'
        Mut $UbuRef (Join-Path $T 'cu.json') 'set-limit', 'read_ahead_kb', '128,4096'
        $r = Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin
        $r.Code | Should -Be 1
        Mut $UbuRef (Join-Path $T 'cu.json') 'set-limit', 'mount_options', 'rw,relatime'
        $r = Compare-Inv $UbuRef (Join-Path $T 'cu.json') $UbuPin
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
        WriteJson @{ image_version = '20261018.275.1' } $p
        Mut $WinRef (Join-Path $T 'c.json') 'copy'
        (Compare-Inv $WinRef (Join-Path $T 'c.json') $p).Code | Should -Be 1
    }
    It 'certify requires a pin: none is exit 2, an incomplete or malformed pin is exit 2' {
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        (Full $WinRef (Join-Path $T 'cand.json') $null $GoodRes 'nopin' -NoPin).Code | Should -Be 2
        $p = Join-Path $T 'pin-short.json'
        WriteJson @{ image_version = '20261007.264.1'; runner_version = '2.337.0'; source_sha = $Sha; workflow_sha = $Wsha } $p
        $r = Full $WinRef (Join-Path $T 'cand.json') $p $GoodRes 'pinshort'
        $r.Code | Should -Be 2
        $r.Out | Should -Match 'action_shas'
        $p = Join-Path $T 'pin-bad.json'
        WriteJson @{ image_version = '20261007.264.1'; runner_version = '2.337.0'; source_sha = 'abc123'; workflow_sha = $Wsha; action_shas = @($Act) } $p
        (Full $WinRef (Join-Path $T 'cand.json') $p $GoodRes 'pinbad').Code | Should -Be 2
        Test-Path (Join-Path $T 'nopin\verdict.json') | Should -BeFalse
    }
    It 'a reference with no recorded identity (null SHAs) fails certification even against a full pin' {
        $noid = Join-Path $T 'win-ref-noid.json'
        (Cert @('parse-hosted-log', $WinLog, '--out', $noid)).Code | Should -Be 0
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        $r = Full $noid (Join-Path $T 'cand.json') $WinPin $GoodRes 'noid'
        $r.Code | Should -Be 1
        $rep = Report $r.Dir
        $rep.inventory.identity.status | Should -Be 'fail'
        (@($rep.inventory.identity.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.field })) | Should -Contain 'source_sha'
        (Verdict $r.Dir).verdict | Should -Be 'fail'
    }
}

Describe 'Workload runner' {
    BeforeAll {
        function script:One { param($Def, [string]$Name)
            $d = NewDefs $Name @($Def)
            $r = RunWl $d $Name
            $r | Add-Member -NotePropertyName Res -NotePropertyValue ((J $r.ResFile).results[0]) -PassThru
        }
    }
    It 'the shipped fixture workloads pass, with exit code, artifact hash and first causal error captured' {
        $res = (J $FixRes).results
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
    It 'Maven BUILD FAILURE with exit code 0 is forged-green' {
        $r = One @{ id = 'forge/maven'; commands = @(, @('{python}', '-c', "print('[INFO] BUILD FAILURE')")) } 'forgemvn'
        $r.Res.status | Should -Be 'forged-green'
    }
    It 'rustc error[E0425] is the first causal error, with the location from the --> line' {
        $r = One (PyDef 'neg/rustc' $RustErr @{ expected_exit_codes = @(1); expected_first_error = @{ contains = 'E0425'; file = 'src/main.rs'; line = 2 } }) 'rustc'
        $r.Res.first_error.message | Should -Match 'E0425'
        $r.Res.first_error.file | Should -Be 'src/main.rs'
        $r.Res.first_error.line | Should -Be 2
        $r.Res.status | Should -Be 'pass'
        $r.Code | Should -Be 0
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
    It 'a timeout kills the whole process tree: a daemon grandchild cannot outlive it or hang the harness' {
        $d = NewDefs 'tree1' @((PyDef 'tree/timeout' ($GrandChild + "`ntime.sleep(40)`n") @{ timeout_s = 3 }))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = RunWl $d 'tree1'
        $sw.Stop()
        $r.Code | Should -Be 1
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 25
        $res = (J $r.ResFile).results[0]
        $res.status | Should -Be 'timeout'
        $res.observed | Should -Be 'timeout'
        $pidFile = Get-ChildItem (Join-Path $T 'wk-tree1') -Recurse -Filter gc.pid | Select-Object -First 1
        $pidFile | Should -Not -BeNullOrEmpty
        $gc = [int](Get-Content -Raw $pidFile.FullName)
        $alive = $true
        for ($i = 0; $i -lt 50 -and $alive; $i++) { $alive = [bool](Get-Process -Id $gc -ErrorAction SilentlyContinue); if ($alive) { Start-Sleep -Milliseconds 100 } }
        $alive | Should -BeFalse
    }
    It 'a daemon that outlives its parent (holding the output handle) neither blocks the harness nor survives the workload' {
        $d = NewDefs 'tree2' @((PyDef 'tree/orphan' $GrandChild))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = RunWl $d 'tree2'
        $sw.Stop()
        $r.Code | Should -Be 0
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 25
        $pidFile = Get-ChildItem (Join-Path $T 'wk-tree2') -Recurse -Filter gc.pid | Select-Object -First 1
        $pidFile | Should -Not -BeNullOrEmpty
        $gc = [int](Get-Content -Raw $pidFile.FullName)
        $alive = $true
        for ($i = 0; $i -lt 50 -and $alive; $i++) { $alive = [bool](Get-Process -Id $gc -ErrorAction SilentlyContinue); if ($alive) { Start-Sleep -Milliseconds 100 } }
        $alive | Should -BeFalse
    }
}

Describe 'Certify: inventory and behaviour are separate sections' {
    It 'identical inventories + all workloads + pins pass, and the evidence records validate' {
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        $r = Full $WinRef (Join-Path $T 'cand.json') $WinPin $GoodRes 'ok1'
        $r.Code | Should -Be 0 -Because $r.Out
        $v = Verdict $r.Dir
        $v.verdict | Should -Be 'pass'
        $v.inventory | Should -Be 'pass'
        $v.behaviour | Should -Be 'pass'
        $v.evidence_validation | Should -Be 'pass'
        $rep = Report $r.Dir
        $rep.inventory.status | Should -Be 'pass'
        $rep.behaviour.status | Should -Be 'pass'
        $rep.PSObject.Properties.Name | Should -Not -Contain 'verdict'
        $files = @(Get-ChildItem (Join-Path $r.Dir 'evidence') -Filter *.json | ForEach-Object { $_.FullName })
        $files.Count | Should -Be 4   # one inventory record + three workloads
        $val = Run (@('-I', $Validate, 'evidence-bundle') + $files)
        $val.Code | Should -Be 0 -Because $val.Out
        $rec = J (Join-Path $r.Dir 'evidence\inventory__windows-2025-vs2026.json')
        $rec.reference_image.image_version | Should -Be '20261007.264.1'
        $rec.head_sha | Should -Be $Sha
        $rec.result | Should -Be 'pass'
        $rec.artifacts.Count | Should -Be 3
    }
    It 'skipping a workload fails certification and is recorded as skipped, never as pass' {
        $res = J $GoodRes
        $res.results = @($res.results | Where-Object { $_.id -ne 'fixture/artifact-hash' })
        $p = Join-Path (Split-Path $GoodRes) 'skip-results.json'
        WriteJson $res $p
        $r = Full $WinRef (Join-Path $T 'cand.json') $WinPin $p 'skip1'
        $r.Code | Should -Be 1
        $rep = Report $r.Dir
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
        (Report $r.Dir).behaviour.status | Should -Be 'missing'
        (Verdict $r.Dir).verdict | Should -Be 'fail'
    }
    It 'behaviour alone cannot substitute for inventory: a broken inventory fails with every workload green' {
        Mut $WinRef (Join-Path $T 'bad.json') 'drop-cache', 'Python', '3.10.11'
        $r = Full $WinRef (Join-Path $T 'bad.json') $WinPin $GoodRes 'noinv'
        $r.Code | Should -Be 1
        $rep = Report $r.Dir
        $rep.behaviour.status | Should -Be 'pass'
        $rep.inventory.status | Should -Be 'fail'
        (J (Join-Path $r.Dir 'evidence\inventory__windows-2025-vs2026.json')).result | Should -Be 'fail'
        $files = @(Get-ChildItem (Join-Path $r.Dir 'evidence') -Filter *.json | ForEach-Object { $_.FullName })
        (Run (@('-I', $Validate, 'evidence-bundle') + $files)).Code | Should -Be 0
    }
    It 'a forged-green workload result fails certification and its record is a valid non-pass' {
        $d = NewDefs 'forgecert' @(@{ id = 'forge/green'; expected_exit_codes = @(2); commands = @(, @('{python}', '-c', "import sys; print('BUILD SUCCESSFUL'); sys.exit(2)")) })
        $w = RunWl $d 'forgecert'
        $w.Code | Should -Be 1
        $r = Full $WinRef (Join-Path $T 'cand.json') $WinPin $w.ResFile 'forge-out' -DefsDir $d
        $r.Code | Should -Be 1 -Because $r.Out
        $rec = J (Join-Path $r.Dir 'evidence\workload__forge__green.json')
        $rec.result | Should -Be 'fail'
        $rec.oracle.observed | Should -Be 'unknown'
    }
    It 'a mismatched source, workflow, action or image identity fails the full certification' {
        $n = 0
        foreach ($c in @(@('set-identity', 'source_sha', ('e' * 40)), @('set-identity', 'workflow_sha', ('e' * 40)),
                @('set-identity', 'action_shas', ('actions/checkout@' + ('e' * 40))), @('set-image', 'image_version', '20261018.275.1'))) {
            $n++
            Mut $WinRef (Join-Path $T 'idm.json') $c
            $r = Full $WinRef (Join-Path $T 'idm.json') $WinPin $GoodRes "idm$n"
            $r.Code | Should -Be 1 -Because ($c -join ' ')
            (Report $r.Dir).inventory.identity.status | Should -Be 'fail'
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

Describe 'Certify recomputes behaviour from the definitions; results.json status is never trusted' {
    BeforeAll {
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        $script:Cand = Join-Path $T 'cand.json'
        function script:CopyResults { param([string]$Name)
            $dst = Join-Path $T ("rc-" + $Name)
            Copy-Item (Split-Path $GoodRes) $dst -Recurse -Force
            Join-Path $dst 'results.json'
        }
    }
    It 'editing a failed result to status pass does not make it pass' {
        $d = NewDefs 'tamper1' @(@{ id = 'neg/wrong-exit'; expected_exit_codes = @(0); commands = @(, @('{python}', '-c', 'import sys; sys.exit(5)')) })
        $w = RunWl $d 'tamper1'
        $w.Code | Should -Be 1
        $j = J $w.ResFile
        $j.results[0].status = 'pass'
        $j.results[0].reasons = @()
        $p = Join-Path (Split-Path $w.ResFile) 'results-tampered.json'
        WriteJson $j $p
        $r = Full $WinRef $Cand $WinPin $p 'tamper1' -DefsDir $d
        $r.Code | Should -Be 1
        $row = (Report $r.Dir).behaviour.results[0]
        $row.status | Should -Be 'fail'
        $row.reasons -join ';' | Should -Match 'exit code 5'
    }
    It 'results produced from a different definition (relaxed expectations) do not certify against the real one' {
        $relaxed = NewDefs 'defrelaxed' @(@{ id = 'x/relaxed'; description = 'relaxed'; expected_exit_codes = @(5); commands = @(, @('{python}', '-c', 'import sys; sys.exit(5)')) })
        $strict = NewDefs 'defstrict' @(@{ id = 'x/relaxed'; description = 'strict'; expected_exit_codes = @(5); commands = @(, @('{python}', '-c', 'import sys; sys.exit(5)')) })
        $w = RunWl $relaxed 'defrelaxed'
        $w.Code | Should -Be 0
        (Full $WinRef $Cand $WinPin $w.ResFile 'defok' -DefsDir $relaxed).Code | Should -Be 0
        $r = Full $WinRef $Cand $WinPin $w.ResFile 'defbad' -DefsDir $strict
        $r.Code | Should -Be 1
        (Report $r.Dir).behaviour.results[0].reasons -join ';' | Should -Match 'not produced from this definition'
    }
    It 'a log that does not match its recorded hash fails' {
        $p = CopyResults 'logtamper'
        Add-Content -LiteralPath (Join-Path (Split-Path $p) 'logs\fixture__py-hello.log') -Value 'BUILD SUCCESSFUL'
        $r = Full $WinRef $Cand $WinPin $p 'logtamper'
        $r.Code | Should -Be 1
        (Report $r.Dir).behaviour.results | Where-Object { $_.id -eq 'fixture/py-hello' } | ForEach-Object { $_.reasons -join ';' } | Should -Match 'log missing or does not match'
    }
    It 'a fallback variant never certifies on its own; it can only certify when the reference ran the same variant' {
        $d = NewDefs 'fallback' @(@{ id = 'fb/needs-compiler'; variants = @(
                    @{ requires = 'aap-no-such-compiler-xyz'; commands = @(, @('aap-no-such-compiler-xyz', '--version')) },
                    @{ requires = $null; commands = @(, @('{python}', '-c', "print('fallback')")) }) })
        $w = RunWl $d 'fallback'
        $w.Code | Should -Be 0   # as a harness self-test the fallback runs fine
        (J $w.ResFile).results[0].variant_index | Should -Be 1
        $r = Full $WinRef $Cand $WinPin $w.ResFile 'fb1' -DefsDir $d
        $r.Code | Should -Be 1
        (Report $r.Dir).behaviour.results[0].reasons -join ';' | Should -Match 'first declared variant'
        $ref = RunWl $d 'fallbackref'
        $r = Full $WinRef $Cand $WinPin $w.ResFile 'fb2' -DefsDir $d -RefResults $ref.ResFile
        $r.Code | Should -Be 0 -Because $r.Out
    }
    It 'a definition with a single variant needs no reference and certifies' {
        (Full $WinRef $Cand $WinPin $GoodRes 'single').Code | Should -Be 0
    }
    It 'a reference result missing for a workload fails the row (not skipped)' {
        $ref = CopyResults 'refmissing'
        $j = J $ref
        $j.results = @($j.results | Where-Object { $_.id -ne 'fixture/py-hello' })
        WriteJson $j $ref
        $r = Full $WinRef $Cand $WinPin $GoodRes 'refmiss' -RefResults $ref
        $r.Code | Should -Be 1
        $row = (Report $r.Dir).behaviour.results | Where-Object { $_.id -eq 'fixture/py-hello' }
        $row.status | Should -Be 'fail'
        $row.reasons -join ';' | Should -Match 'reference result missing'
    }
    It 'a reference that fails its own oracle is invalid evidence and fails certification' {
        $d = NewDefs 'gated' @((PyDef 'gate/env' "import os, sys; sys.exit(0 if os.environ.get('AAP_GATE') == '1' else 3)"))
        $old = $env:AAP_GATE
        try {
            Remove-Item Env:AAP_GATE -ErrorAction SilentlyContinue
            $refRun = RunWl $d 'gated-ref'
            $env:AAP_GATE = '1'
            $candRun = RunWl $d 'gated-cand'
            $env:AAP_GATE = '1'
            $refRun2 = RunWl $d 'gated-ref2'
        }
        finally { if ($null -ne $old) { $env:AAP_GATE = $old } else { Remove-Item Env:AAP_GATE -ErrorAction SilentlyContinue } }
        $refRun.Code | Should -Be 1
        $candRun.Code | Should -Be 0
        $r = Full $WinRef $Cand $WinPin $candRun.ResFile 'refbad' -DefsDir $d -RefResults $refRun.ResFile
        $r.Code | Should -Be 1
        (Report $r.Dir).behaviour.results[0].reasons -join ';' | Should -Match 'reference result does not match its own oracle'
        (Full $WinRef $Cand $WinPin $candRun.ResFile 'refgood' -DefsDir $d -RefResults $refRun2.ResFile).Code | Should -Be 0
    }
    It 'a candidate that differs from a valid reference run fails (sha256, the default and the explicit mode)' {
        $code = "import os; open('o.bin','wb').write(os.urandom(8))"
        foreach ($mode in 'default', 'sha256') {
            $extra = @{ artifact_globs = @('o.bin') }
            if ($mode -eq 'sha256') { $extra.compare_artifacts = 'sha256' }
            $hashDefs = NewDefs "cmphash-$mode" @((PyDef 'cmp/random' $code $extra))
            $a = RunWl $hashDefs "cmph-a-$mode"; $b = RunWl $hashDefs "cmph-b-$mode"
            $r = Full $WinRef $Cand $WinPin $a.ResFile "cmph-$mode" -DefsDir $hashDefs -RefResults $b.ResFile
            $r.Code | Should -Be 1 -Because $mode
            (Report $r.Dir).behaviour.results[0].reasons -join ';' | Should -Match 'artifacts differ'
        }
    }
}

Describe 'compare_artifacts is validated and every waiver stays visible' {
    BeforeAll {
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        $script:Cand = Join-Path $T 'cand.json'
        $script:Why = 'random bytes differ on every run; the artifact name is still compared'
        $script:RandCode = "import os; open('o.bin','wb').write(os.urandom(8))"
        $script:NameCode = "import os; open(os.environ.get('AAP_NAME', 'o') + '.bin', 'wb').write(b'x')"
    }
    It 'names without a non-empty reason is refused by run-workloads and certify (exit 2)' {
        $cases = @(
            @{ compare_artifacts = 'names' },
            @{ compare_artifacts = 'names'; compare_artifacts_reason = '' },
            @{ compare_artifacts = 'names'; compare_artifacts_reason = '   ' },
            @{ compare_artifacts = 'names'; compare_artifacts_reason = 5 }
        )
        $i = 0
        foreach ($extra in $cases) {
            $i++
            $d = NewDefs "wn$i" @((PyDef 'w/noreason' 'pass' $extra))
            $r = RunWl $d "wn$i"
            $r.Code | Should -Be 2 -Because "case $i"
            $r.Out | Should -Match 'compare_artifacts'
            (Full $WinRef $Cand $WinPin $GoodRes "wn$i" -DefsDir $d).Code | Should -Be 2 -Because "certify case $i"
        }
    }
    It 'a variant that waives the comparison without a reason is refused too' {
        $d = NewDefs 'wnvar' @(@{ id = 'w/variant'; variants = @(@{ requires = $null; commands = @(, @('{python}', '-c', 'pass')); compare_artifacts = 'names' }) })
        (RunWl $d 'wnvar').Code | Should -Be 2
    }
    It 'any other mode is refused (exit 2), including a wrong case and an explicit null' {
        $i = 0
        foreach ($mode in 'md5', 'hash', 'NAMES', 'none', $null) {
            $i++
            $d = NewDefs "wm$i" @((PyDef 'w/mode' 'pass' @{ compare_artifacts = $mode; compare_artifacts_reason = 'because' }))
            $r = RunWl $d "wm$i"
            $r.Code | Should -Be 2 -Because "mode $mode"
            $r.Out | Should -Match "sha256"
        }
    }
    It 'the explicit sha256 mode is accepted' {
        $d = NewDefs 'wsha' @((PyDef 'w/sha' 'pass' @{ compare_artifacts = 'sha256' }))
        (RunWl $d 'wsha').Code | Should -Be 0
    }
    It 'the shipped c-hello fixture carries a real reason for its waiver' {
        $f = J (Join-Path $FixDefs 'fixture-c-hello.json')
        $f.compare_artifacts | Should -Be 'names'
        $f.compare_artifacts_reason | Should -Match 'timestamps'
    }
    It 'a names waiver with a reason limits the comparison to artifact names and is visible in the report, the verdict and the evidence record' {
        $nameDefs = NewDefs 'cmpname' @((PyDef 'cmp/random' $RandCode @{ artifact_globs = @('o.bin'); compare_artifacts = 'names'; compare_artifacts_reason = $Why }))
        $a = RunWl $nameDefs 'cmpn-a'; $b = RunWl $nameDefs 'cmpn-b'
        $r = Full $WinRef $Cand $WinPin $a.ResFile 'cmpn' -DefsDir $nameDefs -RefResults $b.ResFile
        $r.Code | Should -Be 0 -Because $r.Out
        $rep = Report $r.Dir
        $rep.behaviour.results[0].compare_artifacts | Should -Be 'names'
        $rep.behaviour.results[0].compare_artifacts_reason | Should -Be $Why
        $rep.behaviour.PSObject.Properties.Name | Should -Contain 'waivers'
        @($rep.behaviour.waivers).Count | Should -Be 1
        $rep.behaviour.waivers[0].workload | Should -Be 'cmp/random'
        $rep.behaviour.waivers[0].reason | Should -Be $Why
        (Verdict $r.Dir).waivers[0].reason | Should -Be $Why
        $rec = J (Join-Path $r.Dir 'evidence\workload__cmp__random.json')
        $rec.command | Should -Match 'waiver compare_artifacts=names: random bytes differ on every run'
        $rec.command.Length | Should -BeLessOrEqual 500
        $rec.result | Should -Be 'pass'
        # a definition with no waiver carries none
        $plain = Report (Join-Path $T 'ok1')
        @($plain.behaviour.waivers).Count | Should -Be 0
        (J (Join-Path $T 'ok1\evidence\workload__fixture__py-hello.json')).command | Should -Not -Match 'waiver'
    }
    It 'names mode still compares the artifact names' {
        $nameDefs = NewDefs 'cmpname2' @((PyDef 'cmp/named' $NameCode @{ artifact_globs = @('*.bin'); compare_artifacts = 'names'; compare_artifacts_reason = $Why }))
        $old = $env:AAP_NAME
        try {
            $env:AAP_NAME = 'one'; $a = RunWl $nameDefs 'cmpn2-a'
            $env:AAP_NAME = 'two'; $b = RunWl $nameDefs 'cmpn2-b'
        }
        finally { if ($null -ne $old) { $env:AAP_NAME = $old } else { Remove-Item Env:AAP_NAME -ErrorAction SilentlyContinue } }
        $r = Full $WinRef $Cand $WinPin $a.ResFile 'cmpn2' -DefsDir $nameDefs -RefResults $b.ResFile
        $r.Code | Should -Be 1
        (Report $r.Dir).behaviour.results[0].reasons -join ';' | Should -Match 'artifacts differ'
    }
    It 'expected_hashes still apply in names mode' {
        $d = NewDefs 'cmpexp' @((PyDef 'cmp/expected' "open('out.txt','wb').write(b'x')" @{ artifact_globs = @('out.txt'); compare_artifacts = 'names'; compare_artifacts_reason = $Why
                    expected_hashes = @{ 'out.txt' = ('0' * 64) } }))
        $r = RunWl $d 'cmpexp'
        $r.Code | Should -Be 1
        ((J $r.ResFile).results[0].reasons -join ';') | Should -Match 'artifact hash mismatch: out.txt'
    }
    It 'names mode is inert without --reference-results: the waiver is listed but nothing is compared' {
        $nameDefs = NewDefs 'cmpname3' @((PyDef 'cmp/random' $RandCode @{ artifact_globs = @('o.bin'); compare_artifacts = 'names'; compare_artifacts_reason = $Why }))
        $a = RunWl $nameDefs 'cmpn3-a'
        $r = Full $WinRef $Cand $WinPin $a.ResFile 'cmpn3' -DefsDir $nameDefs
        $r.Code | Should -Be 0 -Because $r.Out
        $rep = Report $r.Dir
        $rep.behaviour.PSObject.Properties.Name | Should -Contain 'waivers'
        @($rep.behaviour.waivers).Count | Should -Be 1
        $rep.behaviour.waivers[0].reason | Should -Be $Why
    }
}

Describe 'The verdict is written last and fails closed' {
    It 'an evidence record the contract rejects gives exit 3, a failing verdict and no passing report' {
        $acts = 1..65 | ForEach-Object { 'actions/act{0}@{1}' -f $_, ('{0:x40}' -f $_) }
        $many = Join-Path $T 'win-ref-many.json'
        $args1 = @('parse-hosted-log', $WinLog, '--out', $many, '--source-sha', $Sha, '--workflow-sha', $Wsha)
        foreach ($x in $acts) { $args1 += @('--action-sha', $x) }
        (Cert $args1).Code | Should -Be 0
        $pin = Join-Path $T 'pin-many.json'
        WriteJson @{ image_version = '20261007.264.1'; runner_version = '2.337.0'; source_sha = $Sha; workflow_sha = $Wsha; action_shas = @($acts) } $pin
        Mut $many (Join-Path $T 'cand-many.json') 'copy'
        $r = Full $many (Join-Path $T 'cand-many.json') $pin $GoodRes 'badevidence'
        $r.Code | Should -Be 3
        $v = Verdict $r.Dir
        $v.verdict | Should -Be 'fail'
        $v.evidence_validation | Should -Be 'fail'
        $v.inventory | Should -Be 'pass'
        (Report $r.Dir).PSObject.Properties.Name | Should -Not -Contain 'verdict'
        (Get-Content -Raw (Join-Path $r.Dir 'parity-report.json')) | Should -Not -Match '"verdict"\s*:\s*"pass"'
    }
    It 'a missing validate.py fails closed (exit 3, verdict fail) instead of printing a warning and passing' {
        $orphan = Join-Path $T 'orphan\tools\parity-certify'
        New-Item -ItemType Directory -Path $orphan -Force | Out-Null
        Copy-Item $Certify (Join-Path $orphan 'certify.py')
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        $r = Full $WinRef (Join-Path $T 'cand.json') $WinPin $GoodRes 'novalidator' -CertifyPath (Join-Path $orphan 'certify.py')
        $r.Code | Should -Be 3
        $r.Out | Should -Match 'NOT validated'
        $v = Verdict $r.Dir
        $v.verdict | Should -Be 'fail'
        $v.evidence_validation | Should -Be 'unavailable'
    }
    It 'a stale passing verdict from an earlier run is removed when the next run does not finish' {
        Mut $WinRef (Join-Path $T 'cand.json') 'copy'
        $ok = Full $WinRef (Join-Path $T 'cand.json') $WinPin $GoodRes 'stale'
        $ok.Code | Should -Be 0
        (Verdict $ok.Dir).verdict | Should -Be 'pass'
        # same output directory, now an unusable head SHA: the run dies before it can write a verdict
        $a = @('certify', '--reference', $WinRef, '--candidate', (Join-Path $T 'cand.json'), '--pin', $WinPin, '--allowlist', $Allow,
            '--out', $ok.Dir, '--head-sha', 'nothex', '--defs', $GoodDefs, '--results', $GoodRes)
        (Cert $a).Code | Should -Be 2
        Test-Path (Join-Path $ok.Dir 'verdict.json') | Should -BeFalse
    }
}

Describe 'Windows probe: this host, safe mode, writes only under tmp' {
    BeforeAll {
        $script:Probe = Join-Path $Tool 'probe\windows.ps1'
        $script:PDir = Join-Path $T 'probe'
        $script:POut = Join-Path $PDir 'job-inventory.json'
        $script:Before = @(Get-ChildItem $T -Recurse -File | ForEach-Object { $_.FullName })
        $script:Exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
        $script:ProbeRun = & $Exe -NoProfile -File $Probe -OutFile $POut -Safe 2>&1 | Out-String
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
        @($new).Count | Should -Be 1
        $new[0] | Should -Be $POut
    }
    It 'never executes a bash that resolves to the WSL launcher or WindowsApps' -Skip:(-not (($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows)) {
        $fake = Join-Path $T 'fakeapps\WindowsApps'
        New-Item -ItemType Directory -Path $fake -Force | Out-Null
        $sentinel = Join-Path $T 'fakeapps\bash-was-run.txt'
        [IO.File]::WriteAllText((Join-Path $fake 'bash.cmd'), "@echo off`r`necho ran> `"$sentinel`"`r`necho GNU bash, version 9.9.9(1)-release`r`n")
        $out = Join-Path $T 'fakeapps\inv.json'
        $oldPath = $env:PATH
        try {
            $env:PATH = $fake + ';' + $oldPath
            & $Exe -NoProfile -File $Probe -OutFile $out -Safe 2>&1 | Out-Null
        }
        finally { $env:PATH = $oldPath }
        Test-Path $sentinel | Should -BeFalse
        (J $out).shells.bash | Should -Be '<not-run:wsl-launcher>'
        # and the comparison fails honestly on the marker instead of passing on an absent value
        $r = Cert @('compare', '--reference', $WinRef, '--candidate', $out, '--sections', 'shells')
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'shells\.bash'
    }
    It 'falls back to %windir% for the System32 guard when SystemRoot is unset' -Skip:(-not (($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows)) {
        # Windows PowerShell 5.1 cannot even start without SystemRoot (CLR load error 8009001d), so the child is pwsh here
        $childExe = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $childExe) { Set-ItResult -Skipped -Because 'pwsh is not installed'; return }
        $fakeRoot = Join-Path $T 'fakewin'
        $sys32 = Join-Path $fakeRoot 'System32'
        New-Item -ItemType Directory -Path $sys32 -Force | Out-Null
        $sentinel = Join-Path $fakeRoot 'bash-was-run.txt'
        [IO.File]::WriteAllText((Join-Path $sys32 'bash.cmd'), "@echo off`r`necho ran> `"$sentinel`"`r`necho GNU bash, version 9.9.9(1)-release`r`n")
        $out = Join-Path $fakeRoot 'inv.json'
        $oldPath = $env:PATH; $oldRoot = $env:SystemRoot; $oldWin = $env:windir; $oldEap = $ErrorActionPreference
        try {
            $env:PATH = $sys32 + ';' + $oldPath
            Remove-Item Env:SystemRoot
            $env:windir = $fakeRoot
            $ErrorActionPreference = 'Continue'   # the probe's own powershell.exe call prints to stderr without SystemRoot
            & $childExe -NoProfile -File $Probe -OutFile $out -Safe 2>&1 | Out-Null
        }
        finally { $ErrorActionPreference = $oldEap; $env:PATH = $oldPath; $env:SystemRoot = $oldRoot; $env:windir = $oldWin }
        Test-Path $out | Should -BeTrue
        Test-Path $sentinel | Should -BeFalse
        (J $out).shells.bash | Should -Be '<not-run:wsl-launcher>'
    }
}

Describe 'Linux probe' {
    # Git for Windows bash only: the bash on PATH may be the WSL launcher, which this suite must never start.
    BeforeAll { $script:GitBash = 'C:\Program Files\Git\bin\bash.exe' }
    It 'passes a bash syntax check (Git bash; skipped when absent)' -Skip:(-not (Test-Path 'C:\Program Files\Git\bin\bash.exe')) {
        $posix = (Join-Path $Tool 'probe\linux.sh') -replace '\\', '/'
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & $GitBash -n $posix 2>&1 | Out-Null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
        $code | Should -Be 0
    }
    It 'safe mode reports passwordless_sudo as unknown (null), not false (Git bash smoke, not a Linux result)' -Skip:(-not ((Test-Path 'C:\Program Files\Git\bin\bash.exe') -or $IsLinux)) {
        $bash = if (Test-Path 'C:\Program Files\Git\bin\bash.exe') { 'C:\Program Files\Git\bin\bash.exe' } else { 'bash' }
        $sh = (Join-Path $Tool 'probe\linux.sh') -replace '\\', '/'
        $out = (Join-Path $T 'linux-safe.json') -replace '\\', '/'
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns native stderr into errors
        try { & $bash $sh --safe --out $out 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
        $p = J (Join-Path $T 'linux-safe.json')
        $p.user.PSObject.Properties.Name | Should -Contain 'passwordless_sudo'
        ($null -eq $p.user.passwordless_sudo) | Should -BeTrue
        $p.docker.skipped | Should -BeTrue
        $p.coverage | Should -Not -Contain 'docker'
    }
    It 'runs and emits job-inventory.json (run on real Linux only)' -Skip:($true) {
        # Not run on this Windows host (CLAUDE.md: the bash suite needs a real Linux). On Linux:
        #   bash tools/parity-certify/probe/linux.sh --out job-inventory.json
        $true | Should -BeTrue
    }
}

Describe 'README states the limits reviewers asked to keep visible' {
    BeforeAll { $script:Readme = Get-Content -Raw (Join-Path $Tool 'README.md') }
    It 'documents runner_environment as allowlisted and no longer calls it a gap' {
        $Readme | Should -Match 'image\.runner_environment'
        $Readme | Should -Not -Match 'is NOT allowlisted'
    }
    It 'keeps kernel, read-ahead and mount options as failing differences that P07/P11 must match or justify' {
        $Readme | Should -Match 'image\.kernel'
        $Readme | Should -Match 'limits\.read_ahead_kb'
        $Readme | Should -Match 'limits\.mount_options'
        $Readme | Should -Match 'P07'
        $Readme | Should -Match 'P11'
    }
    It 'carries the P17/P18 review checklist for compare_artifacts waivers' {
        $Readme | Should -Match 'grep -rn compare_artifacts parity/workloads'
        $Readme | Should -Match 'expected_hashes. still apply in .names. mode'
        $Readme | Should -Match 'reachable only through .--reference-results'
    }
    It 'says the Readme inventory cannot be compared against a probe candidate and that P24 owns full reconciliation' {
        $Readme | Should -Match 'Readme inventory cannot be compared against a probe candidate'
        $Readme | Should -Match 'P24'
    }
}
