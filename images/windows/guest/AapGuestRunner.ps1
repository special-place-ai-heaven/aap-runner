# Runs one P06 build phase inside the build guest and prints one JSON reply line. Windows PowerShell 5.1.
# The host sends the request file over PowerShell Direct and starts this script with -File. It never downloads anything
# itself: the upstream scripts it runs come from the P03-verified runner-images archive, each checked against the SHA-256
# pinned in the build plan before it runs. Those scripts then download and run installers from the internet, so the host
# treats this guest and its replies as hostile. Upstream script output goes to log files under C:\aap-build\logs, never
# to the reply. The reply holds fixed fields and printable ASCII only.
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File AapGuestRunner.ps1 -RequestPath <request.json>
# A request marked elevated runs this script again as a scheduled task of the install user with highest privileges
# (-Inner -ReplyPath), as Packer runs elevated provisioners; before sysprep, -RegistryCheck runs the same way as SYSTEM.
param(
    [string]$RequestPath,
    [string]$WorkRoot = 'C:\aap-build',
    [switch]$Inner,
    [string]$ReplyPath,
    [string]$RegistryCheck
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$TaskNotRun = 267011      # SCHED_S_TASK_HAS_NOT_RUN
$TaskRunning = 267009     # SCHED_S_TASK_RUNNING
$RegistryRules = @('autologon-password', 'autologon-enabled', 'lsa-default-password')

function Get-Printable([string]$Text) {
    if ($null -eq $Text) { return '' }
    $t = [regex]::Replace($Text, '[^\x20-\x7e]', '?')
    if ($t.Length -gt 400) { $t = $t.Substring(0, 400) }
    return $t
}
function Get-Sha256([string]$Path) {
    $h = [Security.Cryptography.SHA256]::Create(); $s = [IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToLowerInvariant() } finally { $s.Dispose(); $h.Dispose() }
}
function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}
function Send-Reply([string]$Phase, [string]$Status, [string]$Message, $Scripts, $Data) {
    $o = [ordered]@{ schema = 1; phase = $Phase; status = $Status; message = (Get-Printable $Message) }
    if ($null -ne $Scripts) { $o["scripts"] = [object[]]@($Scripts | ForEach-Object { $_ }) }
    if ($null -ne $Data) { $o["data"] = $Data }
    $line = ConvertTo-Json -InputObject $o -Depth 5 -Compress
    if ($ReplyPath) { [IO.File]::WriteAllText($ReplyPath, $line, [Text.Encoding]::ASCII) } else { [Console]::Out.WriteLine($line) }
}

# One child process, no window, its own environment additions, output to a log file. Returns the exit code.
function Invoke-Child([string]$File, [string[]]$Arguments, $Environment, [string]$Log) {
    $saved = @{}
    foreach ($k in @($Environment.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Environment[$k]) }
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
        return [int]$p.ExitCode
    } finally {
        foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# Packer's powershell provisioner runs each script as  & { $ProgressPreference='SilentlyContinue'; <env>; &'<script>'; exit $LastExitCode }.
# The same wrapper goes into a file beside the logs and runs with -File, so the exit codes match upstream: a script that
# throws exits 1, one that ends after a native command exits with that command's code, any other ends with 0.
function New-Wrapper([string]$Script, $Environment, [string]$Path) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($Environment.Keys)) { $lines.Add("`$env:$k = '$(([string]$Environment[$k]).Replace("'", "''"))'") }
    $lines.Add("& { `$ProgressPreference = 'SilentlyContinue'; & '$($Script.Replace("'", "''"))'; exit `$LastExitCode }")
    [IO.File]::WriteAllLines($Path, $lines.ToArray())
}

function Invoke-Scripts($Req, [string]$ScriptsRoot, [string]$Logs) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $policy = [string]$Req.execution_policy
    if (@('bypass', 'unrestricted', 'remotesigned') -notcontains $policy) { return @{ Status = 'failed'; Message = "execution policy $policy"; Scripts = @() } }
    $codes = @($Req.valid_exit_codes | ForEach-Object { [int]$_ })
    $envMap = [ordered]@{}
    foreach ($e in $Req.env.PSObject.Properties) {
        if ($e.Name -cnotmatch '^[A-Z0-9_]{1,40}$' -or [string]$e.Value -cnotmatch '^[\x20-\x7e]*$') { return @{ Status = 'failed'; Message = "environment entry $($e.Name)"; Scripts = @() } }
        $envMap[$e.Name] = [string]$e.Value
    }
    if ([int]$Req.pause_before_seconds -gt 0) { Start-Sleep -Seconds ([int]$Req.pause_before_seconds) }
    $done = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($Req.scripts)) {
        $name = [string]$s.name
        if ($name -cnotmatch '^[A-Za-z0-9._-]{1,80}\.ps1$' -or @('build', 'tests') -cnotcontains [string]$s.dir) { return @{ Status = 'failed'; Message = "script name $name"; Scripts = $done } }
        $path = Join-Path (Join-Path $ScriptsRoot $s.dir) $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{ Status = 'failed'; Message = "$name is not in the staged sources"; Scripts = $done } }
        $sha = Get-Sha256 $path
        if ([string]$s.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $sha -cne [string]$s.sha256) { return @{ Status = 'failed'; Message = "$name SHA-256 differs from the plan; not run"; Scripts = $done } }
        $log = Join-Path $Logs "$($Req.phase)-$name.log"
        $wrapper = "$log.wrapper.ps1"
        New-Wrapper $path $envMap $wrapper
        $start = Get-Date
        $code = Invoke-Child $ps @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', $policy, '-File', "`"$wrapper`"") @{} $log
        $done.Add([ordered]@{ name = $name; sha256 = $sha; exit_code = $code; seconds = [int]((Get-Date) - $start).TotalSeconds })
        if ($codes -notcontains $code) { return @{ Status = 'failed'; Message = "$name exited $code"; Scripts = $done } }
    }
    return @{ Status = 'ok'; Message = ''; Scripts = $done }
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSeconds, [int]$Every = 15) {
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $until) { if (& $Condition) { return $true }; Start-Sleep -Seconds $Every }
    return [bool](& $Condition)
}

# Runs this script again as a scheduled task, waits for it to finish and returns its exit code. Elevated phases run as the
# install user with highest privileges (S4U: no password is stored in the task); the registry check runs as SYSTEM. Tasks
# of these logon types run in session 0, so no window opens.
function Invoke-AsTask([string]$UserId, [string]$LogonType, [string]$Arguments, [int]$TimeoutSeconds) {
    $name = 'aap-build-' + [guid]::NewGuid().ToString('n').Substring(0, 12)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Arguments"
    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType $LogonType -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    [void](Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings)
    try {
        Start-ScheduledTask -TaskName $name
        [void](Wait-Until { $r = (Get-ScheduledTaskInfo -TaskName $name).LastTaskResult; (Get-ScheduledTask -TaskName $name).State -ne 'Running' -and $r -ne $TaskNotRun -and $r -ne $TaskRunning } ($TimeoutSeconds + 60) 5)
        return [int](Get-ScheduledTaskInfo -TaskName $name).LastTaskResult
    } finally { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
}

# As SYSTEM: the autologon values and the LSA DefaultPassword secret, which only SYSTEM can read. Writes which rules were
# checked, which found something and which could not be read; never a value.
function Write-RegistryCheck([string]$Out) {
    $checked = New-Object System.Collections.Generic.List[string]
    $found = New-Object System.Collections.Generic.List[string]
    $unreadable = New-Object System.Collections.Generic.List[string]
    try {
        $v = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        $checked.Add('autologon-password'); $checked.Add('autologon-enabled')
        if ([string](Get-Prop $v 'DefaultPassword') -ne '') { $found.Add('autologon-password') }
        if ([string](Get-Prop $v 'AutoAdminLogon') -eq '1') { $found.Add('autologon-enabled') }
    } catch { $unreadable.Add('autologon-password'); $unreadable.Add('autologon-enabled') }
    try {
        $null = Get-ChildItem -LiteralPath 'HKLM:\SECURITY\Policy\Secrets' -ErrorAction Stop
        $checked.Add('lsa-default-password')
        if (Test-Path -LiteralPath 'HKLM:\SECURITY\Policy\Secrets\DefaultPassword') { $found.Add('lsa-default-password') }
    } catch { $unreadable.Add('lsa-default-password') }
    $o = [ordered]@{ checked = [object[]]$checked.ToArray(); findings = [object[]]$found.ToArray(); unreadable = [object[]]$unreadable.ToArray() }
    [IO.File]::WriteAllText($Out, (ConvertTo-Json -InputObject $o -Compress), [Text.Encoding]::ASCII)
}

function Expand-Sources([string]$Zip, [string]$Dest) {
    # .NET Framework 4.6.2+ refuses entries that would land outside $Dest. The archive is P03-verified; this is defense in depth.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $raw = "$Dest.raw"
    if (Test-Path -LiteralPath $raw) { Remove-Item -LiteralPath $raw -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $raw)
    $top = @(Get-ChildItem -LiteralPath $raw -Directory)
    if ($top.Count -ne 1) { throw 'the archive must hold exactly one top-level folder' }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    Move-Item -LiteralPath $top[0].FullName -Destination $Dest
    Remove-Item -LiteralPath $raw -Recurse -Force
}

function Remove-AnswerFiles {
    foreach ($f in @("$env:SystemRoot\Panther\unattend.xml", "$env:SystemRoot\Panther\Unattend\unattend.xml", "$env:SystemRoot\System32\Sysprep\unattend.xml",
            "$env:SystemDrive\unattend.xml", "$env:SystemDrive\autounattend.xml")) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
}

# A random password that never leaves this process, built into a SecureString one character at a time. Replaces the build
# password before sysprep, so the sealed image carries no credential anyone knows.
function Reset-InstallUser([string]$User) {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_=+.,:!@#%'
    $bytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $s = New-Object Security.SecureString
    foreach ($b in $bytes) { $s.AppendChar($alphabet[$b % 68]) }
    foreach ($c in 'Aa1!'.ToCharArray()) { $s.AppendChar($c) }
    $s.MakeReadOnly()
    try { Set-LocalUser -Name $User -Password $s } finally { $s.Dispose() }
}

if ($RegistryCheck) { Write-RegistryCheck $RegistryCheck; exit 0 }

$phase = 'unknown'
try {
    if (-not $RequestPath) { throw 'no request' }
    $req = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($RequestPath))
    $phase = [string]$req.phase
    if ($phase -cnotmatch '^(p[0-9]{2}|verify)$') { $phase = 'unknown'; throw 'bad phase id' }
    $vars = Get-Prop $req 'vars'
    $timeout = [int](Get-Prop $req 'timeout_seconds')
    if ($timeout -lt 1) { $timeout = 21600 }
    $logs = Join-Path $WorkRoot 'logs'
    [void][IO.Directory]::CreateDirectory($logs)
    if ((Get-Prop $req 'elevated') -eq $true -and -not $Inner) {
        $reply = Join-Path $WorkRoot "reply-$phase.json"
        if (Test-Path -LiteralPath $reply) { Remove-Item -LiteralPath $reply -Force }
        $code = Invoke-AsTask ([string]$vars.install_user) 'S4U' "-RequestPath `"$RequestPath`" -WorkRoot `"$WorkRoot`" -Inner -ReplyPath `"$reply`"" $timeout
        if (-not (Test-Path -LiteralPath $reply -PathType Leaf) -or (Get-Item -LiteralPath $reply).Length -gt 65536) { throw "the elevated task ended without a reply (task result $code)" }
        [Console]::Out.WriteLine(([IO.File]::ReadAllText($reply)).Trim())
        Remove-Item -LiteralPath $reply -Force
        exit 0
    }
    $src = Join-Path $WorkRoot 'src'
    $scriptsRoot = Join-Path $src 'images\windows\scripts'
    if ($req.kind -ceq 'scripts') {
        $r = Invoke-Scripts $req $scriptsRoot $logs
        Send-Reply $phase $r.Status $r.Message $r.Scripts $null
        exit 0
    }
    if ($req.kind -cne 'action') { throw "unknown request kind" }
    $imageFolder = [string]$vars.image_folder
    $ok = $true; $msg = ''; $data = $null
    switch -CaseSensitive ([string]$req.action) {
        'prepare-folders' {
            if (-not (Test-Path -LiteralPath 'D:\')) { throw 'the temp disk is not D:' }
            [void](New-Item -Path $imageFolder -ItemType Directory -Force)
            [void](New-Item -Path ([string]$vars.temp_dir) -ItemType Directory -Force)
        }
        'upload-sources' {
            Expand-Sources (Join-Path $WorkRoot 'runner-images.zip') $src
            foreach ($d in 'assets', 'scripts', 'toolsets') { Copy-Item -LiteralPath (Join-Path $src "images\windows\$d") -Destination $imageFolder -Recurse -Force }
        }
        'upload-report-base' {
            $docs = Join-Path $imageFolder 'scripts\docs-gen'
            [void](New-Item -Path $docs -ItemType Directory -Force)
            Copy-Item -LiteralPath (Join-Path $src 'helpers\software-report-base') -Destination $docs -Recurse -Force
        }
        'layout-image-folder' {
            # The upstream inline block, in its order, with the template variables resolved.
            $helpers = [string]$vars.helper_script_folder
            Move-Item (Join-Path $imageFolder 'assets\post-gen') 'C:\post-generation'
            Remove-Item -Recurse (Join-Path $imageFolder 'assets')
            Move-Item (Join-Path $imageFolder 'scripts\docs-gen') (Join-Path $imageFolder 'SoftwareReport')
            Move-Item (Join-Path $imageFolder 'scripts\helpers') (Join-Path $helpers 'ImageHelpers')
            [void](New-Item -Type Directory -Path (Join-Path $helpers 'TestsHelpers\'))
            Move-Item (Join-Path $imageFolder 'scripts\tests\Helpers.psm1') (Join-Path $helpers 'TestsHelpers\TestsHelpers.psm1')
            Move-Item (Join-Path $imageFolder 'scripts\tests') (Join-Path $imageFolder 'tests')
            Remove-Item -Recurse (Join-Path $imageFolder 'scripts')
            Move-Item (Join-Path $imageFolder 'toolsets\toolset-2025-vs2026.json') (Join-Path $imageFolder 'toolset.json')
            Remove-Item -Recurse (Join-Path $imageFolder 'toolsets')
        }
        { $_ -ceq 'create-install-user' -or $_ -ceq 'check-install-user' } {
            $u = [string]$vars.install_user
            if (-not ((net localgroup Administrators) -contains $u)) { $ok = $false; $msg = "$u is not a local administrator" }
        }
        'bcdedit-testsigning' {
            & (Join-Path $env:SystemRoot 'System32\bcdedit.exe') /set TESTSIGNING ON | Out-Null
            if ($LASTEXITCODE -ne 0) { $ok = $false; $msg = "bcdedit exited $LASTEXITCODE (Secure Boot must be off)" }
        }
        'wlansvc-manual' {
            Set-Service -Name wlansvc -StartupType Manual
            if ((Get-Service -Name wlansvc).Status -eq 'Running') { Stop-Service -Name wlansvc }
        }
        'wait-containers-feature' {
            $ok = Wait-Until { (Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction SilentlyContinue).State -eq 'Enabled' } $timeout 30
            if (-not $ok) { $msg = 'Containers feature not enabled' }
        }
        'wait-tiworker-idle' {
            $ok = Wait-Until { -not (Get-Process TiWorker -ErrorAction SilentlyContinue) } $timeout
            if (-not $ok) { $msg = 'TiWorker still running' }
        }
        'wait-no-pending-reboot' {
            $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            $ok = Wait-Until { -not @($keys | Where-Object { Test-Path $_ }).Count } $timeout
            if (-not $ok) { $msg = 'a reboot is still pending' }
        }
        'assert-test-results' {
            if (-not (Test-Path (Join-Path $imageFolder 'tests\testResults.xml'))) { $ok = $false; $msg = 'testResults.xml not found' }
        }
        'software-report' {
            $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
            $code = Invoke-Child $pwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', "`"$(Join-Path $imageFolder 'SoftwareReport\Generate-SoftwareReport.ps1')`"") @{ IMAGE_VERSION = [string]$vars.image_version; IMAGE_FOLDER = $imageFolder } (Join-Path $logs "$phase-software-report.log")
            if ($code -ne 0) { $ok = $false; $msg = "Generate-SoftwareReport exited $code" }
        }
        'assert-software-report' {
            foreach ($f in 'C:\software-report.md', 'C:\software-report.json') { if (-not (Test-Path $f)) { $ok = $false; $msg = "$f not found" } }
        }
        'sysprep-generalize' {
            # Upstream's Configure-User ran earlier; the install user now gets a password nobody knows and is disabled.
            Remove-AnswerFiles
            $u = [string]$vars.install_user
            Reset-InstallUser $u
            Disable-LocalUser -Name $u
            $out = Join-Path $WorkRoot 'registry-check.json'
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
            [void](Invoke-AsTask 'SYSTEM' 'ServiceAccount' "-RegistryCheck `"$out`"" 600)
            $reg = $null
            if ((Test-Path -LiteralPath $out -PathType Leaf) -and (Get-Item -LiteralPath $out).Length -le 4096) { $reg = ConvertFrom-Json ([IO.File]::ReadAllText($out)) }
            if ($null -eq $reg) { $reg = [ordered]@{ checked = [object[]]@(); findings = [object[]]@(); unreadable = [object[]]$RegistryRules } }
            $data = [ordered]@{ registry = $reg }
            if (@($reg.findings).Count -or @($reg.unreadable).Count) {
                $ok = $false; $msg = 'the registry check before sysprep did not pass; sysprep not run'
            } else {
                foreach ($d in 'src', 'runner-images.zip', 'logs', 'request.json', 'registry-check.json') { $x = Join-Path $WorkRoot $d; if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Recurse -Force } }
                & (Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe') /oobe /generalize /mode:vm /quiet /quit
                $ok = Wait-Until { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } 3600 10
                if (-not $ok) { $msg = 'sysprep did not reach IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }
                Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        default { throw "unknown action" }
    }
    Send-Reply $phase $(if ($ok) { 'ok' } else { 'failed' }) $msg $null $data
    exit 0
} catch {
    Send-Reply $phase 'failed' $_.Exception.Message $null $null
    exit 0
}
