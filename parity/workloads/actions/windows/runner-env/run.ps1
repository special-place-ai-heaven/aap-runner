# actions/windows/runner-env: what an Actions job process on this profile sees: default variables (CI, GITHUB_*,
# RUNNER_*), the image's machine variables, file-command files, the tool cache layout the setup-* actions rely on
# (<tool>\<version>\<arch> plus <arch>.complete), service states, Windows-only Docker, privileges and system settings.
# Runs only inside an Actions job. Sabotage no-tool-cache points RUNNER_TOOL_CACHE and AGENT_TOOLSDIRECTORY at an empty
# folder.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\..\..\windows\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    if ($env:GITHUB_ACTIONS -ne 'true') { throw 'not inside a GitHub Actions job (GITHUB_ACTIONS is not true)' }
    if ($Sabotage -eq 'no-tool-cache') {
        $empty = Join-Path $Work 'empty-tool-cache'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        $env:RUNNER_TOOL_CACHE = $empty
        $env:AGENT_TOOLSDIRECTORY = $empty
        Write-Line 'sabotage no-tool-cache applied'
    }
    else {
        foreach ($p in (Get-Oracle 'runner_env').PSObject.Properties) { Add-Fact "env.$($p.Name)" ([Environment]::GetEnvironmentVariable($p.Name)) $p.Value.v }
        foreach ($p in (Get-Oracle 'env').PSObject.Properties) {
            if ($p.Name -in 'RUNNER_TOOL_CACHE', 'AGENT_TOOLSDIRECTORY') { continue }  # checked with the layout below
            Add-Fact "env.$($p.Name)" ([Environment]::GetEnvironmentVariable($p.Name)) $p.Value.v
        }
        Add-Observation 'env.RUNNER_ENVIRONMENT' $env:RUNNER_ENVIRONMENT
        foreach ($n in 'GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'GITHUB_STATE') {
            $f = [Environment]::GetEnvironmentVariable($n)
            Add-Fact "file_command.$n" ([bool]($f -and (Test-Path -LiteralPath (Split-Path -Parent $f)))) $true
        }
        foreach ($n in 'RUNNER_TEMP', 'GITHUB_WORKSPACE') {
            Add-Fact "dir.$n" ([bool]((Get-Item env:$n -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Get-Item env:$n).Value -PathType Container))) $true
        }
        $aac = $env:ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE
        Add-Fact 'dir.ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE' ([bool]($aac -and (Test-Path -LiteralPath $aac -PathType Container))) $true
        foreach ($p in (Get-Oracle 'services').PSObject.Properties) {
            $s = Get-Service -Name $p.Name -ErrorAction SilentlyContinue
            Add-Fact "service.$($p.Name)" $(if ($s) { "$($s.Status)/$($s.StartType)" } else { 'absent' }) "$($p.Value.v.Status)/$($p.Value.v.StartType)"
        }
        $docker = Resolve-Exe 'docker.exe'
        $os = if ($docker) { (Invoke-Tool $docker @('version', '--format', '{{.Server.Os}}') -AllowFail).Lines | Select-Object -Last 1 } else { 'docker not on PATH' }
        Add-Fact 'docker.server_os' $os (Get-Oracle 'docker_server_os')
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        Add-Fact 'user.is_administrator' ((New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) (Get-Oracle 'is_administrator')
        Add-Observation 'user.name' $id.Name
        $reg = @{
            ConsentPromptBehaviorAdmin        = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            LongPathsEnabled                  = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
            AllowDevelopmentWithoutDevLicense = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        }
        foreach ($k in $reg.Keys) { Add-Fact "registry.$k" ((Get-ItemProperty -Path $reg[$k] -Name $k -ErrorAction SilentlyContinue).$k) (Get-Oracle "registry/$k") }
    }
    $cache = Get-Oracle 'env/RUNNER_TOOL_CACHE'
    Add-Fact 'env.RUNNER_TOOL_CACHE' $env:RUNNER_TOOL_CACHE $cache
    Add-Fact 'env.AGENT_TOOLSDIRECTORY' $env:AGENT_TOOLSDIRECTORY (Get-Oracle 'env/AGENT_TOOLSDIRECTORY')
    $arch = Get-Oracle 'tool_cache_arch'
    foreach ($e in (Get-Oracle 'tool_cache')) {
        $tool, $ver = $e.Split('/')
        $a = if ($arch.PSObject.Properties[$tool]) { $arch.$tool } else { 'x64' }
        $dir = "$env:RUNNER_TOOL_CACHE\$tool\$ver"
        Add-Fact "tool_cache.$e" ((Test-Path -LiteralPath (Join-Path $dir $a) -PathType Container) -and (Test-Path -LiteralPath (Join-Path $dir "$a.complete"))) $true
    }
}
