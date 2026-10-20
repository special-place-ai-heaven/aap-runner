# Generates build-plan.json, the P06 phase table, from the pinned upstream Packer template. Reads files only.
#   pwsh -File images/windows/New-AapWinBuildPlan.ps1 [-ScriptsDir <runner-images images\windows\scripts>] [-SourceSha256 <hex>] [-SourceEntry <name>] [-OutFile <path>]
# The template is the byte copy P01 stored for build commit aee0669; its SHA-256 is pinned below and checked first.
# Every upstream provisioner becomes one phase, in template order. Script phases keep their upstream script list, environment,
# elevation, execution policy, accepted exit codes and pause. Inline and file provisioners map to a named AAP action; an inline
# block that matches no known action stops the generator, so a template change cannot slip through unreviewed.
# -ScriptsDir: the upstream scripts folder extracted from the P03-staged source archive. With it, each script's SHA-256 is
# recorded; without it the hash stays null and the builder refuses to run (AAP_ScriptUnpinned).
# -SourceSha256: the SHA-256 of that archive as the P03 manifest entry -SourceEntry pins it. The plan pins both; without the
# hash the plan keeps the p06-upstream-source-archive blocker, which no waiver clears.
param(
    [string]$ScriptsDir,
    [string]$SourceEntry = 'runner-images-aee0669',
    [string]$SourceSha256,
    [string]$OutFile = (Join-Path $PSScriptRoot 'build-plan.json')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 formats JSON differently, so the committed plan is regenerated with PowerShell 7 only.
if ($PSVersionTable.PSVersion.Major -lt 7 -and -not $PSBoundParameters.ContainsKey('OutFile')) { throw 'AAP_PlanHost: regenerate build-plan.json with pwsh 7, or pass -OutFile' }
if ($SourceEntry -cnotmatch '^[a-z0-9][a-z0-9.-]{0,79}\z') { throw 'AAP_PlanSource: -SourceEntry is not a P03 entry name' }
if ($SourceSha256 -and $SourceSha256 -cnotmatch '^[0-9a-f]{64}\z') { throw 'AAP_PlanSource: -SourceSha256 must be 64 lowercase hex digits' }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$base = 'parity/baselines/windows-2025-vs2026-x64'
$templateRel = "$base/sources/build-commit-aee0669/build.windows-2025-vs2026.pkr.hcl"
$templateSha = 'f1057bf63d180ff8392acb2bd0604523fa701a10397dcac5579de52009b35241'
$localsRel = "$base/sources/pin/locals.windows.pkr.hcl"
$localsSha = '4e8051e8e82597087f859f5104859bcaf5b6f63dbc66338ea5ed79d59aed9e27'

function Get-Sha256Text([string]$Text) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
function Read-Pinned([string]$Rel, [string]$Sha) {
    $path = Join-Path $repo ($Rel -replace '/', '\')
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha) { throw "AAP_PlanSourceChanged: $Rel has SHA-256 $actual, expected $Sha" }
    return [IO.File]::ReadAllText($path)
}

$text = Read-Pinned $templateRel $templateSha
$locals = Read-Pinned $localsRel $localsSha
$m = [regex]::Match($locals, '"win25-vs2026"\s*=\s*\{[^}]*os_disk_size_gb\s*=\s*(\d+)')
if (-not $m.Success) { throw 'AAP_PlanSourceChanged: win25-vs2026 os_disk_size_gb not found in the pinned locals' }
$osDiskGib = [int]$m.Groups[1].Value

# Provisioner blocks with brace matching, as parity/baselines/tools/provisioning_order.py does.
$blocks = New-Object System.Collections.Generic.List[object]
foreach ($b in [regex]::Matches($text, 'provisioner "([\w-]+)" \{')) {
    $i = $b.Index + $b.Length; $depth = 1
    while ($depth) { if ($text[$i] -eq '{') { $depth++ } elseif ($text[$i] -eq '}') { $depth-- }; $i++ }
    $blocks.Add([pscustomobject]@{ Type = $b.Groups[1].Value; Body = $text.Substring($b.Index + $b.Length, $i - 1 - $b.Index - $b.Length) })
}

# Inline and file provisioners: a distinctive upstream fragment selects the AAP action that reproduces it.
$actions = @(
    @{ Match = 'New-Item -Path ${var.image_folder} -ItemType Directory'; Action = 'prepare-folders'; Deviation = $null }
    @{ Match = 'destination = "${var.image_folder}\\"'; Action = 'upload-sources'; Deviation = 'assets, scripts and toolsets come from the P03-staged runner-images archive at the build commit, copied into the guest over the management session' }
    @{ Match = 'helpers/software-report-base'; Action = 'upload-report-base'; Deviation = 'from the same P03-staged archive' }
    @{ Match = "Move-Item '`${var.image_folder}\\assets\\post-gen'"; Action = 'layout-image-folder'; Deviation = $null }
    @{ Match = 'net user ${var.install_user}'; Action = 'create-install-user'; Deviation = 'the answer file creates the install user with a per-build random password held in memory only; WinRM basic auth is not enabled because the builder uses PowerShell Direct' }
    @{ Match = '(net localgroup Administrators) -contains'; Action = 'check-install-user'; Deviation = $null }
    @{ Match = 'bcdedit.exe /set TESTSIGNING ON'; Action = 'bcdedit-testsigning'; Deviation = $null }
    @{ Match = 'Set-Service -Name wlansvc'; Action = 'wlansvc-manual'; Deviation = $null }
    @{ Match = 'testResults.xml not found'; Action = 'assert-test-results'; Deviation = $null }
    @{ Match = 'Generate-SoftwareReport.ps1'; Action = 'software-report'; Deviation = $null }
    @{ Match = 'software-report.md not found'; Action = 'assert-software-report'; Deviation = $null }
    @{ Match = 'source      = "C:\\software-report.md"'; Action = 'download-software-report-md'; Deviation = 'copied to the build evidence, size-bounded, never parsed as code' }
    @{ Match = 'source      = "C:\\software-report.json"'; Action = 'download-software-report-json'; Deviation = 'copied to the build evidence, size-bounded, never parsed as code' }
    @{ Match = 'Sysprep.exe /oobe /generalize /mode:vm /quiet /quit'; Action = 'sysprep-generalize'; Deviation = 'before sysprep the builder deletes every answer file and gives the install user a fresh random password that never leaves the guest' }
)

$phases = New-Object System.Collections.Generic.List[object]
$n = 0
foreach ($blk in $blocks) {
    $n++
    $body = $blk.Body
    $up = [ordered]@{ block = $n; type = $blk.Type; body_sha256 = (Get-Sha256Text $body) }
    $row = [ordered]@{ id = ('p{0:d2}' -f $n); kind = $null; action = $null; upstream = $up }
    $scripts = @([regex]::Matches($body, '"\$\{path\.root\}/\.\./scripts/(build|tests)/([^"]+)"') | ForEach-Object {
        $name = $_.Groups[2].Value
        $sha = $null
        if ($ScriptsDir) { $sha = (Get-FileHash -LiteralPath (Join-Path (Join-Path $ScriptsDir $_.Groups[1].Value) $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
        [ordered]@{ name = $name; dir = $_.Groups[1].Value; sha256 = $sha }
    })
    if ($blk.Type -eq 'windows-restart') {
        $row.kind = 'restart'
        $t = [regex]::Match($body, 'restart_timeout\s*=\s*"(\d+)m"')
        $row.timeout_seconds = $(if ($t.Success) { [int]$t.Groups[1].Value * 60 } else { 300 })
        $row.check_registry = ($body -match 'check_registry\s*=\s*true')
        $row.check = $(if ($body -match 'Containers') { 'wait-containers-feature' } elseif ($body -match 'TiWorker') { 'wait-tiworker-idle' } else { $null })
    } elseif ($scripts.Count) {
        $row.kind = 'scripts'
        $row.scripts = $scripts
        $envBlock = [regex]::Match($body, 'environment_vars\s*=\s*\[([^\]]*)\]')
        $env = [ordered]@{}
        if ($envBlock.Success) { foreach ($e in [regex]::Matches($envBlock.Groups[1].Value, '"([A-Z0-9_]+)=([^"]*)"')) { $env[$e.Groups[1].Value] = $e.Groups[2].Value } }
        $row.env = $env
        $row.elevated = ($body -match 'elevated_user')
        $p = [regex]::Match($body, 'execution_policy\s*=\s*"(\w+)"')
        $row.execution_policy = $(if ($p.Success) { $p.Groups[1].Value } else { 'bypass' })
        $codes = [regex]::Match($body, 'valid_exit_codes\s*=\s*\[([0-9, ]+)\]')
        $row.valid_exit_codes = @($(if ($codes.Success) { $codes.Groups[1].Value -split '\s*,\s*' | ForEach-Object { [int]$_ } } else { 0 }))
        $pb = [regex]::Match($body, 'pause_before\s*=\s*"(\d+)m(\d+)s"')
        $row.pause_before_seconds = $(if ($pb.Success) { [int]$pb.Groups[1].Value * 60 + [int]$pb.Groups[2].Value } else { 0 })
        $row.skip_clean = ($body -match 'skip_clean\s*=\s*true')
    } else {
        $hit = @($actions | Where-Object { $body.Contains($_.Match) })
        if ($hit.Count -ne 1) { throw "AAP_PlanUnmapped: upstream provisioner $n ($($blk.Type)) matches $($hit.Count) AAP actions; review it and map it" }
        $row.kind = 'action'
        $row.action = $hit[0].Action
        $row.deviation = $hit[0].Deviation
        $row.elevated = ($body -match 'elevated_user')
    }
    $phases.Add($row)
}

# Steps the builder adds around the upstream order. They run in the guest like the upstream phases.
$plan = [ordered]@{
    schema           = 1
    profile          = 'win25-vs2026-x64'
    generated_by     = 'images/windows/New-AapWinBuildPlan.ps1'
    baseline         = [ordered]@{
        runner_images_commit = 'aee0669dd04510a11756664eb77f5630debabed3'
        image_version        = '20261007.264.1'
        inventory_path       = "$base/inventory.json"
        inventory_sha256     = 'cf842a07fd309da0100d955383883f9423bb2b7524e78bd33a67ecdcfc953f25'
        template_path        = $templateRel
        template_sha256      = $templateSha
        locals_path          = $localsRel
        locals_sha256        = $localsSha
    }
    os_disk_gib      = $osDiskGib
    temp_disk_gib    = $osDiskGib
    variables        = [ordered]@{
        image_version         = '20261007.264.1'
        image_os              = 'win25-vs2026'
        agent_tools_directory = 'C:\hostedtoolcache\windows'
        imagedata_file        = 'C:\imagedata.json'
        image_folder          = 'C:\image'
        temp_dir              = 'D:\temp'
        helper_script_folder  = 'C:\Program Files\WindowsPowerShell\Modules\'
        install_user          = 'installer'
    }
    variables_source = 'upstream images/windows/templates/variable.windows.pkr.hcl defaults at aee0669, not stored in parity/baselines; image_version is the P01 baseline'
    source           = [ordered]@{ entry = $SourceEntry; sha256 = $(if ($SourceSha256) { $SourceSha256 } else { $null }) }
    blockers         = @(
        if (-not $SourceSha256) { [ordered]@{ id = 'p06-upstream-source-archive'; reason = 'images/common/artifacts.manifest.json has no entry for the actions/runner-images tree at aee0669 (images/windows scripts, assets, toolsets and helpers/software-report-base). The builder copies the upstream scripts only from a P03-verified archive whose SHA-256 this plan pins. No waiver clears this blocker.'; owner_action = 'P03 owner adds a literal-pinned entry for the archive of actions/runner-images at aee0669dd04510a11756664eb77f5630debabed3, then this generator is rerun with -ScriptsDir and -SourceSha256 to pin every script hash and the archive.' } }
        [ordered]@{ id = 'p06-upstream-variables-unverified'; reason = 'The variable defaults above come from the upstream variables file, which P01 did not store. They are not yet checked against the pinned bytes.'; owner_action = 'Compare them with variable.windows.pkr.hcl inside the P03-staged archive and drop this blocker in the same change.' }
    )
    phases           = $phases
}

$json = (ConvertTo-Json -InputObject $plan -Depth 10) -replace "`r`n", "`n"
[IO.File]::WriteAllText($OutFile, $json + "`n", (New-Object Text.UTF8Encoding($false)))
"wrote $OutFile ($($phases.Count) phases, os disk $osDiskGib GiB)"
