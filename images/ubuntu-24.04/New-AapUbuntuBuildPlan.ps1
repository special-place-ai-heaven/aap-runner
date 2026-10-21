# Generates build-plan.json, the P07 phase table, from the pinned upstream Packer template. Reads files only.
#   pwsh -File images/ubuntu-24.04/New-AapUbuntuBuildPlan.ps1 [-ScriptsDir <runner-images images/ubuntu/scripts>]
#       [-SourceEntry <P03 entry> -SourceSha256 <hex>] [-MediaEntry <P03 entry> -MediaSha256 <hex>] [-OutFile <path>]
# The template is the byte copy P01 stored for build commit 7e7dc1b; it, the locals, the toolset and the hosted capture log
# are pinned by SHA-256 below and checked first. Every upstream provisioner becomes one phase, in template order. Script
# phases keep their upstream script list, environment, the way Packer ran them (root through sudo, root through pwsh, or
# the unprivileged build user), pause and start retry. Inline and file provisioners map to a named AAP action; a block that
# matches no known action stops the generator, so a template change cannot slip through unreviewed.
# -ScriptsDir: the upstream scripts folder extracted from the P03-staged source archive. With it, each script's SHA-256 is
# recorded; without it the hash stays null and the builder refuses to run (AAP_ScriptUnpinned).
# -SourceEntry/-SourceSha256 and -MediaEntry/-MediaSha256: the P03 manifest entries of the upstream source archive and the
# Ubuntu ISO with the SHA-256 their staged files must have. Until a pair is given, the plan carries its unwaivable blocker.
param(
    [string]$ScriptsDir,
    [string]$SourceEntry, [string]$SourceSha256, [string]$MediaEntry, [string]$MediaSha256,
    [string]$OutFile = (Join-Path $PSScriptRoot 'build-plan.json')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 formats JSON differently, so the committed plan is regenerated with PowerShell 7 only.
if ($PSVersionTable.PSVersion.Major -lt 7 -and -not $PSBoundParameters.ContainsKey('OutFile')) { throw 'AAP_PlanHost: regenerate build-plan.json with pwsh 7, or pass -OutFile' }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$base = 'parity/baselines/ubuntu-24.04-x64'
$templateRel = "$base/sources/build-commit-7e7dc1b/build.ubuntu-24_04.pkr.hcl"
$templateSha = '5b8a5f29c33d9c98a0368c0e3109eba9dc566ce8091aa412de56fc93518d1adf'
$localsRel = "$base/sources/pin/locals.ubuntu.pkr.hcl"
$localsSha = '9de904fe6c77708d0c22506ae61411f61bd97e036f405569f32c7616d15958cf'
$toolsetRel = "$base/sources/build-commit-7e7dc1b/toolset-2404.json"
$toolsetSha = '6ebf0669d768e4cc222d2ae25f9382c86c694e42dc1694db5f5cf50eca611264'
$captureRel = "$base/sources/hosted-capture-39305649952.log"
$captureSha = 'a03a47b43be146c12c629db937481ffd5eb3b9ec89f2db16fe794b5929edebee'
$referenceRel = 'images/ubuntu-24.04/reference-inventory.json'

function Get-Sha256Text([string]$Text) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $h.Dispose() }
}
function Get-Sha256Rel([string]$Rel) { (Get-FileHash -LiteralPath (Join-Path $repo ($Rel -replace '/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant() }
function Read-Pinned([string]$Rel, [string]$Sha) {
    $actual = Get-Sha256Rel $Rel
    if ($actual -ne $Sha) { throw "AAP_PlanSourceChanged: $Rel has SHA-256 $actual, expected $Sha" }
    return [IO.File]::ReadAllText((Join-Path $repo ($Rel -replace '/', '\')))
}

$text = Read-Pinned $templateRel $templateSha
$locals = Read-Pinned $localsRel $localsSha
$null = Read-Pinned $toolsetRel $toolsetSha
$capture = Read-Pinned $captureRel $captureSha
# Only the ubuntu24 entry: the locals also list Ubuntu 22.04 and 26.04, which this profile never builds.
$m = [regex]::Match($locals, '"ubuntu24"\s*=\s*\{[^}]*source_image_marketplace_sku\s*=\s*"([^"]+)"[^}]*os_disk_size_gb\s*=\s*(\d+)')
if (-not $m.Success) { throw 'AAP_PlanSourceChanged: ubuntu24 not found in the pinned locals' }
$sourceSku = $m.Groups[1].Value
$upstreamOsDiskGb = [int]$m.Groups[2].Value
# The hosted job sees a 150G sda (the Azure deployment grows the 75 GB build disk); a job needs that space, so the base disk
# is sized from the hosted capture, not from the build-time value.
$d = [regex]::Match($capture, '(?m)\tHardware class\t\S+ sda\s+(\d+)G\s+\d+\s+disk\s*$')
if (-not $d.Success) { throw 'AAP_PlanSourceChanged: the hosted capture has no sda size line' }
$osDiskGib = [int]$d.Groups[1].Value

# Provisioner blocks with brace matching, as parity/baselines/tools/provisioning_order.py does.
$blocks = New-Object System.Collections.Generic.List[object]
foreach ($b in [regex]::Matches($text, 'provisioner "([\w-]+)" \{')) {
    $i = $b.Index + $b.Length; $depth = 1
    while ($depth) { if ($text[$i] -eq '{') { $depth++ } elseif ($text[$i] -eq '}') { $depth-- }; $i++ }
    $blocks.Add([pscustomobject]@{ Type = $b.Groups[1].Value; Body = $text.Substring($b.Index + $b.Length, $i - 1 - $b.Index - $b.Length) })
}

# Inline and file provisioners: a distinctive upstream fragment selects the AAP action that reproduces it. File uploads come
# from the P03-verified archive and follow Packer's rule: a folder uploaded to an existing destination lands inside it, to a
# missing destination it becomes that destination.
$actions = @(
    @{ Match = 'inline          = ["mkdir ${var.image_folder}", "chmod 777 ${var.image_folder}"]'; Action = 'make-image-folder'; Deviation = $null }
    @{ Match = 'source      = "${path.root}/../scripts/helpers"'; Action = 'upload-helpers'; Deviation = 'images/ubuntu/scripts/helpers from the P03-staged runner-images archive becomes ${var.helper_script_folder}' }
    @{ Match = 'source      = "${path.root}/../scripts/build"'; Action = 'upload-build-scripts'; Deviation = 'images/ubuntu/scripts/build from the same archive becomes ${var.installer_script_folder}' }
    @{ Match = '"${path.root}/../assets/post-gen",'; Action = 'upload-image-folder'; Deviation = 'assets/post-gen, scripts/tests and scripts/docs-gen from the same archive land inside ${var.image_folder}' }
    @{ Match = 'helpers/software-report-base'; Action = 'upload-report-base'; Deviation = 'helpers/software-report-base from the same archive lands inside ${var.image_folder}/docs-gen' }
    @{ Match = 'toolsets/toolset-2404.json'; Action = 'upload-toolset'; Deviation = 'from the same archive' }
    @{ Match = 'mv ${var.image_folder}/docs-gen ${var.image_folder}/SoftwareReport'; Action = 'layout-image-folder'; Deviation = $null }
    @{ Match = 'Generate-SoftwareReport.ps1 -OutputDirectory'; Action = 'software-report-and-tests'; Deviation = $null }
    @{ Match = 'source      = "${var.image_folder}/software-report.md"'; Action = 'download-software-report-md'; Deviation = 'copied to the build evidence, size-bounded, never parsed as code' }
    @{ Match = 'source      = "${var.image_folder}/software-report.json"'; Action = 'download-software-report-json'; Deviation = 'copied to the build evidence, size-bounded, never parsed as code' }
    @{ Match = '/usr/sbin/waagent -force -deprovision+user'; Action = 'deprovision'; Deviation = 'waagent -force -deprovision (waagent provisioned no user here), then the install user, the build agent, cloud-init state and installer logs are removed, cloud-init is pointed at the NoCloud seed, the free space is trimmed, and a seal check runs as root' }
)

$phases = New-Object System.Collections.Generic.List[object]
$n = 0
foreach ($blk in $blocks) {
    $n++
    $body = $blk.Body
    $up = [ordered]@{ block = $n; type = $blk.Type; body_sha256 = (Get-Sha256Text $body) }
    $row = [ordered]@{ id = ('p{0:d2}' -f $n); kind = $null; action = $null; upstream = $up }
    $scripts = @([regex]::Matches($body, '"\$\{path\.root\}/\.\./scripts/build/([^"/]+)"') | ForEach-Object {
            $name = $_.Groups[1].Value
            $sha = $null
            if ($ScriptsDir) { $sha = (Get-FileHash -LiteralPath (Join-Path (Join-Path $ScriptsDir 'build') $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
            [ordered]@{ name = $name; sha256 = $sha }
        })
    $exec = 'user'
    $ec = [regex]::Match($body, 'execute_command\s*=\s*"([^"]*)"')
    if ($ec.Success) {
        $cmd = $ec.Groups[1].Value
        if ($cmd -ceq "sudo sh -c '{{ .Vars }} pwsh -f {{ .Path }}'") { $exec = 'root-pwsh' }
        elseif ($cmd -ceq "sudo sh -c '{{ .Vars }} {{ .Path }}'") { $exec = 'root' }
        elseif ($cmd -ceq "/bin/sh -c '{{ .Vars }} {{ .Path }}'") { $exec = 'user' }
        else { throw "AAP_PlanUnmapped: upstream provisioner $n has execute_command $cmd" }
    }
    $pb = [regex]::Match($body, 'pause_before\s*=\s*"(\d+)m(\d+)s"')
    $pause = $(if ($pb.Success) { [int]$pb.Groups[1].Value * 60 + [int]$pb.Groups[2].Value } else { 0 })
    if ($blk.Type -eq 'shell' -and $body -match 'expect_disconnect\s*=\s*true') {
        if ($body -notmatch '"sudo reboot"') { throw "AAP_PlanUnmapped: upstream provisioner $n disconnects without a reboot" }
        $row.kind = 'restart'
        $row.timeout_seconds = 1800
    } elseif ($scripts.Count) {
        $row.kind = 'scripts'
        $row.scripts = $scripts
        $envBlock = [regex]::Match($body, 'environment_vars\s*=\s*\[([^\]]*)\]')
        $env = [ordered]@{}
        if ($envBlock.Success) { foreach ($e in [regex]::Matches($envBlock.Groups[1].Value, '"([A-Z0-9_]+)=([^"]*)"')) { $env[$e.Groups[1].Value] = $e.Groups[2].Value } }
        $row.env = $env
        $row.exec = $exec
        $row.valid_exit_codes = @(0)
        $row.pause_before_seconds = $pause
        $sr = [regex]::Match($body, 'start_retry_timeout\s*=\s*"(\d+)m"')
        $row.start_retry_seconds = $(if ($sr.Success) { [int]$sr.Groups[1].Value * 60 } else { 300 })
    } else {
        $hit = @($actions | Where-Object { $body.Contains($_.Match) })
        if ($hit.Count -ne 1) { throw "AAP_PlanUnmapped: upstream provisioner $n ($($blk.Type)) matches $($hit.Count) AAP actions; review it and map it" }
        $row.kind = 'action'
        $row.action = $hit[0].Action
        $row.deviation = $hit[0].Deviation
        # Packer's file provisioner uploaded over SFTP as the build user.
        $row.exec = $(if ($blk.Type -eq 'file') { 'user' } else { $exec })
        $envBlock = [regex]::Match($body, 'environment_vars\s*=\s*\[([^\]]*)\]')
        $env = [ordered]@{}
        if ($envBlock.Success) { foreach ($e in [regex]::Matches($envBlock.Groups[1].Value, '"([A-Z0-9_]+)=([^"]*)"')) { $env[$e.Groups[1].Value] = $e.Groups[2].Value } }
        $row.env = $env
    }
    $phases.Add($row)
}

$plan = [ordered]@{
    schema            = 1
    profile           = 'ubuntu-24.04-x64'
    generated_by      = 'images/ubuntu-24.04/New-AapUbuntuBuildPlan.ps1'
    baseline          = [ordered]@{
        runner_images_commit = '7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe'
        image_version        = '20261012.334.1'
        inventory_path       = "$base/inventory.json"
        inventory_sha256     = (Get-Sha256Rel "$base/inventory.json")
        template_path        = $templateRel
        template_sha256      = $templateSha
        locals_path          = $localsRel
        locals_sha256        = $localsSha
        toolset_path         = $toolsetRel
        toolset_sha256       = $toolsetSha
        capture_path         = $captureRel
        capture_sha256       = $captureSha
        upstream_source_sku  = $sourceSku
        upstream_os_disk_gb  = $upstreamOsDiskGb
    }
    os_disk_gib       = $osDiskGib
    variables         = [ordered]@{
        image_version           = '20261012.334.1'
        image_os                = 'ubuntu24'
        image_folder            = '/imagegeneration'
        helper_script_folder    = '/imagegeneration/helpers'
        installer_script_folder = '/imagegeneration/installers'
        imagedata_file          = '/imagegeneration/imagedata.json'
        install_user            = 'installer'
    }
    variables_source  = 'upstream images/ubuntu/templates/variable.ubuntu.pkr.hcl defaults at 7e7dc1b, not stored in parity/baselines; image_folder is the P01 baseline (/imagegeneration), image_os the hosted ImageOS, image_version the P01 baseline'
    # The local base for the Azure Marketplace image (a P03 blocker, azure-base-image-ubuntu-24.04, waived only by the chair):
    # the official 24.04 live-server ISO, installed unattended with the Azure kernel flavour and agent the hosted image runs.
    base              = [ordered]@{
        boot_command        = @('<wait5>', 'c', '<wait2>', "linux /casper/vmlinuz --- autoinstall ds=nocloud<enter>", '<wait2>', 'initrd /casper/initrd<enter>', '<wait2>', 'boot<enter>')
        kernel_package      = 'linux-azure'
        packages            = @('walinuxagent')
        masked_services     = @('walinuxagent.service')
        install_timeout_seconds = 5400
        deviation           = 'the hosted base is the Azure Marketplace image canonical:ubuntu-24_04-lts:server; this build installs the 24.04 live-server ISO with linux-azure and walinuxagent (masked: there is no Azure fabric), an ext4 root on GPT (EFI + root) and no swap file'
    }
    channel           = [ordered]@{ vsock_port = 5223; service_guid = '00001467-facb-11e6-bd58-64006a7986d3' }
    job_user          = [ordered]@{ name = 'runner'; uid = 1001; groups = @('adm', 'users', 'docker', 'systemd-journal') }
    post_generation   = '/imagegeneration/post-generation'
    verify            = [ordered]@{
        reference_path   = $referenceRel
        reference_sha256 = (Get-Sha256Rel $referenceRel)
        allowlist_path   = 'tools/parity-certify/allowlist.json'
        # tool_cache.defaults is not gated: the hosted capture records no defaults, so the reference has nothing to compare.
        gate_sections    = @('coverage', 'tool_cache', 'services', 'path.process', 'path.machine', 'action_archive_cache', 'user')
        # Missing-required (the reference has it, the image lacks it) fails only in the sections the image owns. Not image,
        # infra, run_identity or credential_env: the runner (a verification guest has none, so image.runner_version,
        # runner_os and runner_arch are null), the job's identity and the Azure fabric. Not docker.images either: the six cached
        # images are :latest pulls inside install-docker.sh (P03 blocker ubuntu-floating-container-images; the toolset's list
        # is empty), so no pinned input says which names a build gets; they are recorded for P24 until a pin names them.
        required_sections = @('tools', 'shells', 'docker', 'env', 'limits', 'limits.sysctl', 'hardware', 'tool_cache', 'action_archive_cache', 'services', 'path.process', 'path.machine')
    }
    inputs            = [ordered]@{
        source = [ordered]@{ entry = $(if ($SourceEntry) { $SourceEntry } else { $null }); sha256 = $(if ($SourceSha256) { $SourceSha256.ToLowerInvariant() } else { $null }) }
        media  = [ordered]@{ entry = $(if ($MediaEntry) { $MediaEntry } else { $null }); sha256 = $(if ($MediaSha256) { $MediaSha256.ToLowerInvariant() } else { $null }) }
    }
    blockers          = @(
        if (-not ($SourceEntry -and $SourceSha256)) { [ordered]@{ id = 'p07-upstream-source-archive'; waivable = $false; reason = 'images/common/artifacts.manifest.json has no entry for the actions/runner-images tree at 7e7dc1b (images/ubuntu scripts, assets, toolsets and helpers/software-report-base). The builder copies the upstream scripts only from a P03-verified archive, pinned here in inputs.source.'; owner_action = 'P03 owner adds a literal-pinned entry for the archive of actions/runner-images at 7e7dc1bcc0ef464e5e315a2b4c33609590c6cffe, then this generator is rerun with -ScriptsDir, -SourceEntry and -SourceSha256.' } }
        [ordered]@{ id = 'p07-upstream-variables-unverified'; waivable = $true; reason = 'The variable defaults above come from the upstream variables file, which P01 did not store. They are not yet checked against the pinned bytes.'; owner_action = 'Compare them with variable.ubuntu.pkr.hcl inside the P03-staged archive and drop this blocker in the same change.' }
        if (-not ($MediaEntry -and $MediaSha256)) { [ordered]@{ id = 'p07-ubuntu-server-media'; waivable = $false; reason = 'The Ubuntu 24.04 live-server ISO is not a P03 manifest entry, so nothing ties the media a build boots to the signed Canonical SHA256SUMS.'; owner_action = 'P03 adds the ISO with Canonical''s signed SHA256SUMS as its hash source and records the point release (the hosted image reports 24.04.5); this generator is rerun with -MediaEntry and -MediaSha256.' } }
    )
    phases            = $phases
}

$json = (ConvertTo-Json -InputObject $plan -Depth 10) -replace "`r`n", "`n"
[IO.File]::WriteAllText($OutFile, $json + "`n", (New-Object Text.UTF8Encoding($false)))
"wrote $OutFile ($($phases.Count) phases, os disk $osDiskGib GiB)"
