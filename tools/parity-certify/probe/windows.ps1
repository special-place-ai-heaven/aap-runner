<#
.SYNOPSIS
  Windows job probe. Runs INSIDE a job (hosted or local) and writes one job-inventory.json.
.DESCRIPTION
  Same shape and meaning as `certify.py parse-hosted-log` produces from the hosted capture log.
  Works on Windows PowerShell 5.1 and pwsh 7. Never dumps the environment: the variable names are
  fixed below, and credential-bearing variables are recorded as presence only.
  -Safe skips Docker (no daemon call) and is the mode for a developer host; Docker is then left out of
  `coverage`, so a comparison reports it as not probed instead of silently passing.
.PARAMETER OutFile
  Where to write job-inventory.json. Parent directory is created. Nothing else is written.
.PARAMETER RunnerVersion
  Actions runner version when the job environment does not provide RUNNER_VERSION (it is null otherwise,
  and a pinned-identity comparison then fails loudly).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutFile,
    [switch]$Safe,
    [string]$RunnerVersion
)
$ErrorActionPreference = 'Stop'

function Get-Env([string]$n) { [Environment]::GetEnvironmentVariable($n) }
function Norm([string]$p) { $p.Replace('\', '/').TrimEnd('/').ToLowerInvariant() }
function Try-Run([scriptblock]$b) { try { & $b } catch { $null } }

# Fixed allow-list: the hosted-reference workflow list plus the Readme "Environment variables" names.
$envNames = 'ImageOS', 'ImageVersion', 'AGENT_TOOLSDIRECTORY', 'RUNNER_TOOL_CACHE', 'ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE',
    'JAVA_HOME', 'JAVA_HOME_17_X64', 'GOROOT_1_24_X64', 'VCPKG_INSTALLATION_ROOT', 'CONDA', 'ANDROID_HOME', 'ANDROID_NDK',
    'ANDROID_NDK_HOME', 'ANDROID_NDK_LATEST_HOME', 'ANDROID_NDK_ROOT', 'ANDROID_SDK_ROOT',
    'CHROMEWEBDRIVER', 'EDGEWEBDRIVER', 'GECKOWEBDRIVER', 'SELENIUM_JAR_PATH', 'DOTNET_MULTILEVEL_LOOKUP', 'DOTNET_NOLOGO',
    'DOTNET_SKIP_FIRST_TIME_EXPERIENCE', 'POWERSHELL_UPDATECHECK', 'GCM_INTERACTIVE', 'PIPX_BIN_DIR', 'PIPX_HOME',
    'PGBIN', 'PGROOT', 'PGDATA', 'PGUSER', 'VCINSTALLDIR', 'VSINSTALLDIR', 'VSCMD_VER', 'INCLUDE', 'LIB', 'LIBPATH', 'Platform',
    'ZCCACHE_DIR'
$credNames = 'PGPASSWORD', 'GITHUB_TOKEN', 'ACTIONS_RUNTIME_TOKEN'
$services = 'wuauserv', 'DiagTrack', 'SysMain', 'docker', 'postgresql-x64-17', 'MongoDB', 'Apache', 'nginx', 'wlansvc', 'WinDefend', 'WSLService'
$cmds = 'cl.exe', 'link.exe', 'clang-cl.exe', 'cmake.exe', 'ninja.exe', 'msbuild.exe'

$inv = [ordered]@{
    schema = 1; kind = 'job-inventory'
    source = [ordered]@{ type = 'probe'; ref = 'tools/parity-certify/probe/windows.ps1' }
    coverage = @(); profile = $null
}

# --- image identity
$label = Get-Env 'AAP_IMAGE_LABEL'
if (-not $label -and (Test-Path 'C:\imagedata.json')) {
    $img = (Get-Content -Raw 'C:\imagedata.json' | ConvertFrom-Json) | Where-Object { $_.group -eq 'Runner Image' }
    if ($img -and $img.detail -match '(?m)^Image: (\S+)') { $label = $Matches[1] }
}
$os = Try-Run { Get-CimInstance Win32_OperatingSystem }
$rv = $RunnerVersion
if (-not $rv) { $rv = Get-Env 'RUNNER_VERSION' }
if (-not $rv) { $rv = Get-Env 'AAP_RUNNER_VERSION' }
$inv.profile = $label
$inv.image = [ordered]@{
    label = $label; image_version = (Get-Env 'ImageVersion'); image_os = (Get-Env 'ImageOS'); runner_version = $rv
    runner_os = (Get-Env 'RUNNER_OS'); runner_arch = (Get-Env 'RUNNER_ARCH'); runner_environment = (Get-Env 'RUNNER_ENVIRONMENT')
    os_name = $(if ($os) { $os.Caption } else { $null }); os_build = $(if ($os) { $os.Version } else { $null })
}
$inv.infra = [ordered]@{ hostname = ([Environment]::MachineName).ToLowerInvariant() }
$actions = @(); $a = Get-Env 'AAP_PARITY_ACTION_SHAS'
if ($a) { $actions = @($a.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) }
$inv.run_identity = [ordered]@{ source_sha = (Get-Env 'GITHUB_SHA'); workflow_sha = (Get-Env 'GITHUB_WORKFLOW_SHA'); action_shas = $actions }

# --- user, privileges
$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$uac = Try-Run { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').ConsentPromptBehaviorAdmin }
$ep = [ordered]@{}
Try-Run { Get-ExecutionPolicy -List | ForEach-Object { $ep[$_.Scope.ToString()] = $_.ExecutionPolicy.ToString() } } | Out-Null
$inv.user = [ordered]@{
    name = [Environment]::UserName; is_admin = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    uac_consent = $uac; execution_policy = $ep
}

# --- environment (names fixed above; credential-bearing names are presence only)
$e = [ordered]@{}
foreach ($n in $envNames) { $v = Get-Env $n; if ($null -ne $v) { $e[$n] = $v } else { $e[$n] = '<unset>' } }
$inv.env = $e
$c = [ordered]@{}
foreach ($n in $credNames) { $c[$n] = ($null -ne (Get-Env $n)) }
$inv.credential_env = $c

# --- PATH order
$split = { param($s) if ($s) { @($s -split ';' | Where-Object { $_ -ne '' }) } else { @() } }
$inv.path = [ordered]@{
    process = @(& $split (Get-Env 'PATH'))
    machine = @(& $split ([Environment]::GetEnvironmentVariable('PATH', 'Machine')))
}

# --- shells, tools, command resolution
$shells = [ordered]@{}
$pw = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pw) { $shells.pwsh = Try-Run { (& $pw.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') | Select-Object -First 1 } }
$wp = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wp) { $shells.powershell = Try-Run { (& $wp.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') | Select-Object -First 1 } }
$bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bash) {
    # System32\bash.exe and the WindowsApps alias are the WSL launcher: running it would start WSL. Never run it;
    # record a marker so the comparison fails honestly instead of passing on an absent value.
    $bsrc = [string]$bash.Source
    $sysRoot = $env:SystemRoot
    if (-not $sysRoot) { $sysRoot = $env:windir }
    if (($sysRoot -and $bsrc.StartsWith($sysRoot, [StringComparison]::OrdinalIgnoreCase)) -or ($bsrc -like '*\WindowsApps\*')) {
        $shells.bash = '<not-run:wsl-launcher>'
    }
    else {
        $bv = Try-Run { & $bsrc --version 2>$null | Select-Object -First 1 }
        if ($bv -match '^GNU bash, version (\S+)') { $shells.bash = $Matches[1] }
    }
}
$inv.shells = $shells
$tools = [ordered]@{}
if (Test-Path 'C:\shells') {
    $links = [ordered]@{}
    Get-ChildItem 'C:\shells' -File | ForEach-Object { $t = $_.Target; $links[$_.Name] = $(if ($t) { [string]$t } else { '' }) }
    $tools.shell_links = $links
}
$vsw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vsw) {
    $vs = Try-Run { (& $vsw -latest -products * -format json | Out-String) | ConvertFrom-Json }
    if ($vs) {
        $v = @($vs)[0]
        $tools.visual_studio = $v.installationVersion; $tools.visual_studio_product = $v.productId; $tools.visual_studio_path = $v.installationPath
    }
}
$inv.tools = $tools
$cp = [ordered]@{}
foreach ($n in $cmds) {
    $g = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { $cp[$n] = $g.Source }
}
$inv.command_paths = $cp

# --- tool cache layout and defaults (default = first process-PATH entry under <root>/<name>/<ver>/, else JAVA_HOME)
$root = Get-Env 'AGENT_TOOLSDIRECTORY'
$versions = [ordered]@{}; $defaults = [ordered]@{}
if ($root -and (Test-Path $root)) {
    Get-ChildItem $root -Directory | Sort-Object Name | ForEach-Object {
        $name = $_.Name
        $vs2 = @(Get-ChildItem $_.FullName -Directory | Sort-Object Name | ForEach-Object { $_.Name })
        if ($vs2.Count -gt 0) { $versions[$name] = $vs2 }
    }
    $r = (Norm $root) + '/'
    $probePaths = @($inv.path.process | ForEach-Object { Norm $_ })
    $jh = Get-Env 'JAVA_HOME'
    if ($jh) { $probePaths += (Norm $jh) + '/bin' }
    foreach ($pp in $probePaths) {
        if (-not $pp.StartsWith($r)) { continue }
        $parts = $pp.Substring($r.Length).Split('/')
        if ($parts.Count -lt 2) { continue }
        foreach ($name in @($versions.Keys)) {
            if ($name.ToLowerInvariant() -ne $parts[0]) { continue }
            foreach ($ver in $versions[$name]) {
                if ($ver.ToLowerInvariant() -eq $parts[1] -and -not $defaults.Contains($name)) { $defaults[$name] = $ver }
            }
        }
    }
}
$inv.tool_cache = [ordered]@{ root = $(if ($root) { $root } else { $null }); versions = $versions; defaults = $defaults }
$inv.action_archive_cache = @()

# --- services of interest
$svc = [ordered]@{}
foreach ($n in $services) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) { $svc[$n] = [ordered]@{ status = $s.Status.ToString(); start_type = $s.StartType.ToString() } }
}
$inv.services = $svc

# --- docker (skipped in -Safe: no daemon call, and left out of coverage)
$cov = @('image', 'infra', 'run_identity', 'user', 'env', 'credential_env', 'path', 'shells', 'tools', 'command_paths', 'services', 'hardware')
if ($root -and (Test-Path $root)) { $cov += 'tool_cache' }
if ($Safe) { $inv.docker = [ordered]@{ skipped = $true } }
else {
    $d = [ordered]@{ images = @() }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $ver = Try-Run { (& docker version --format '{{.Client.Version}} {{.Server.Version}}' 2>$null) | Select-Object -First 1 }
        if ($ver) { $x = $ver.Split(' '); $d.client = $x[0]; if ($x.Count -gt 1) { $d.server = $x[1] } }
        $d.images = @(Try-Run { & docker images --format '{{.Repository}}:{{.Tag}}' 2>$null } | Sort-Object)
    }
    $inv.docker = $d
    $cov += 'docker'
}

# --- hardware class
$cpu = Try-Run { Get-CimInstance Win32_Processor }
$sysDrive = ($env:SystemDrive).TrimEnd(':')
$free = Try-Run { (Get-PSDrive -Name $sysDrive -PSProvider FileSystem).Free }
$inv.hardware = [ordered]@{
    logical_processors = $(if ($cpu) { [int](($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum) } else { $null })
    memory_bytes = Try-Run { [int64](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }
    root_disk_free_bytes = $free
}
$inv.limits = [ordered]@{}
$inv.coverage = $cov

$dir = Split-Path -Parent ([IO.Path]::GetFullPath($OutFile))
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$json = $inv | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutFile), $json + "`n", (New-Object Text.UTF8Encoding $false))
Write-Output ("probe: wrote {0}; label={1} image_version={2} user={3} admin={4} env_names={5} path_entries={6} tool_cache={7} docker={8}" -f `
        $OutFile, $label, $inv.image.image_version, $inv.user.name, $inv.user.is_admin, $inv.env.Count, $inv.path.process.Count, `
        $versions.Count, $(if ($Safe) { 'skipped' } else { 'probed' }))
