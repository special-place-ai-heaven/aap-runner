# Installs the aap-runner host supervisor. Elevated, idempotent.
# Windows PowerShell 5.1 and PowerShell 7.
#
# - C:\ProgramData\aap-runner and logs: Administrators and SYSTEM full
#   control, the installing user Modify (the non-elevated tray writes
#   state.json and logs\tray.log), nothing for anyone else. Inheritance from
#   ProgramData is cut, because ProgramData grants Users create rights.
# - state.json {"desired":"off"} only if absent.
# - aap-runner-supervisor.ps1 is copied to C:\aap-runner\windows. The task
#   runs elevated, so it must only run code that only admins can change; the
#   copy is refused unless that folder is owned by Administrators and only
#   SYSTEM and Administrators have entries (lock-acl.ps1 set C:\aap-runner).
# - Task AAP-CRRR-Supervisor from aap-runner-supervisor-task.xml: logon
#   trigger, this user's SID, InteractiveToken, the same verified path as
#   AAP-CRRR-Mount-Work-Disk. Logoff stops the runner by design: WSL
#   sessions belong to the logon session.
# - -TrayExe (default C:\TOOLS\git_runner\aap-runner-tray.exe), if the file
#   exists: Run value AAP-Runner-Tray = "<path>" for the installing user, so
#   the tray starts at logon. Missing exe = skipped with an INFO line. The
#   tray is not started.
# The task is not started. -DryRun prints the plan and changes nothing.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$DataDir = 'C:\ProgramData\aap-runner',
    [string]$ScriptDir = 'C:\aap-runner\windows',
    [string]$TaskName = 'AAP-CRRR-Supervisor',
    [string]$TrayExe = 'C:\TOOLS\git_runner\aap-runner-tray.exe'
)

$ErrorActionPreference = 'Stop'

function Initialize-AapModulePath {
    $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    if ([string]::IsNullOrEmpty($machine)) {
        throw 'refusing: machine PSModulePath is empty'
    }
    $env:PSModulePath = $machine
}

function Test-AapElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# Same rule as install-host.ps1: owner Administrators, every entry SYSTEM or
# Administrators.
function Test-AapAdminAcl([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
    if ($null -eq $owner -or $owner.Value -ne 'S-1-5-32-544') { return $false }
    $any = $false
    foreach ($ace in @($acl.Access)) {
        $any = $true
        $id = $ace.IdentityReference
        if ($id -is [Security.Principal.SecurityIdentifier]) {
            $sid = $id.Value
        } else {
            $sid = $id.Translate([Security.Principal.SecurityIdentifier]).Value
        }
        if ($sid -ne 'S-1-5-18' -and $sid -ne 'S-1-5-32-544') { return $false }
    }
    return $any
}

# The SID and path are checked before they go into XML and into the
# single-quoted -Command string of the task.
function Get-AapSupervisorTaskXml {
    param([string]$Template, [string]$UserSid, [string]$Ps1)
    if ($UserSid -notmatch '^S-1-5-21(-\d+){4}$') { throw "refusing: user SID $UserSid" }
    if ($Ps1 -notmatch '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.ps1$') { throw "refusing: script path $Ps1" }
    $xml = $Template.Replace('__AAP_USER_SID__', $UserSid).Replace('__AAP_PS1__', $Ps1)
    if ($xml.Contains('__AAP_')) { throw 'task template still has a placeholder' }
    return $xml
}

# The tray autostarts from the installing user's Run key. This script runs
# elevated, so HKCU is the elevated token's hive. The value goes into
# HKEY_USERS\<SID> of the installing user instead, the same SID the task
# runs as. On Fresh the elevated and the desktop user are the same account,
# so both name the same hive.
function Get-AapRunKey([string]$UserSid) {
    return "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows\CurrentVersion\Run"
}

# Quoted, so a path with spaces starts the exe and not a prefix of it.
function Write-AapTrayRunValue([string]$RunKey, [string]$Exe) {
    if ($Exe -notmatch '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.exe$') { throw "refusing: tray path $Exe" }
    if (-not (Test-Path -LiteralPath $RunKey)) { New-Item -Path $RunKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $RunKey -Name 'AAP-Runner-Tray' -Value ('"' + $Exe + '"') -PropertyType String -Force | Out-Null
}

function Get-AapSupervisorPlan {
    param([hashtable]$Facts)
    $lines = New-Object System.Collections.Generic.List[string]
    $failed = $false
    if ($Facts.Elevated) {
        $lines.Add('PASS elevation admin')
    } elseif ($Facts.DryRun) {
        $lines.Add('INFO elevation not-admin (dry run)')
    } else {
        $lines.Add('FAIL elevation required: run from an elevated PowerShell')
        $failed = $true
    }
    if (-not $failed) {
        $lines.Add("WOULD acl $($Facts.DataDir) and logs: Administrators, SYSTEM full; $($Facts.UserSid) Modify; no inheritance")
        if ($Facts.StateExists) {
            $lines.Add('SKIP state.json already present')
        } else {
            $lines.Add('WOULD state.json {"desired":"off"}')
        }
        $lines.Add("WOULD copy aap-runner-supervisor.ps1 to $($Facts.ScriptDir) (refused unless admin-only ACL)")
        $lines.Add("WOULD task $($Facts.TaskName) logon trigger, InteractiveToken")
        if ($Facts.TrayExists) {
            $lines.Add("WOULD run-key $(Get-AapRunKey $Facts.UserSid) AAP-Runner-Tray = `"$($Facts.TrayExe)`"")
        } else {
            $lines.Add("INFO tray $($Facts.TrayExe) not found; Run value skipped")
        }
        $lines.Add("UNDO: uninstall-supervisor.ps1")
        $lines.Add("NOTE the task is not started. Start it with: Start-ScheduledTask $($Facts.TaskName)")
        $lines.Add('NOTE desired is off by default. A running aap-runner distro is drained and terminated on first start unless state.json says on.')
    }
    $code = 0
    if ($failed) { $code = 1 }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

function Protect-AapDataDir([string]$Path, [string]$UserSid) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($pair in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @($UserSid, 'Modify'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier $pair[0]
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $pair[1], $inherit, $none, 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-AapInstallSupervisor {
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $stateFile = Join-Path $DataDir 'state.json'
    $stateExists = $false
    try { $stateExists = [bool](Test-Path -LiteralPath $stateFile -ErrorAction Stop) } catch { $stateExists = $false }
    $trayExists = [bool](Test-Path -LiteralPath $TrayExe -PathType Leaf)
    if ($trayExists -and $TrayExe -notmatch '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.exe$') { throw "refusing: tray path $TrayExe" }
    $plan = Get-AapSupervisorPlan @{
        Elevated    = (Test-AapElevated)
        DryRun      = [bool]$DryRun
        DataDir     = $DataDir
        ScriptDir   = $ScriptDir
        TaskName    = $TaskName
        UserSid     = $userSid
        StateExists = $stateExists
        TrayExe     = $TrayExe
        TrayExists  = $trayExists
    }
    $template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'aap-runner-supervisor-task.xml')
    $ps1 = Join-Path $ScriptDir 'aap-runner-supervisor.ps1'
    # Rendered on a dry run too, so a bad SID or path fails before any change.
    $xml = Get-AapSupervisorTaskXml -Template $template -UserSid $userSid -Ps1 $ps1
    foreach ($line in $plan.Lines) { [Console]::Out.WriteLine($line) }
    if ($DryRun -or $plan.ExitCode -ne 0) { return [int]$plan.ExitCode }

    foreach ($dir in @($DataDir, (Join-Path $DataDir 'logs'))) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    Protect-AapDataDir $DataDir $userSid
    if (-not (Test-Path -LiteralPath $stateFile)) {
        [IO.File]::WriteAllText($stateFile, '{"desired":"off"}', (New-Object Text.UTF8Encoding($false)))
    }

    if (-not (Test-Path -LiteralPath $ScriptDir)) { New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null }
    if (-not (Test-AapAdminAcl $ScriptDir)) { throw "refusing: $ScriptDir is not owned by Administrators with SYSTEM and Administrators entries only" }
    $src = Join-Path $PSScriptRoot 'aap-runner-supervisor.ps1'
    Copy-Item -LiteralPath $src -Destination $ps1 -Force
    if ((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $ps1).Hash) { throw "copy of $ps1 does not match" }

    $xmlFile = Join-Path $ScriptDir 'aap-runner-supervisor-task.xml'
    # UTF-16 LE with BOM: schtasks /XML rejects UTF-8.
    [IO.File]::WriteAllText($xmlFile, $xml, [Text.Encoding]::Unicode)
    & schtasks.exe /Create /TN $TaskName /XML $xmlFile /F
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create /TN $TaskName failed (exit $LASTEXITCODE)" }
    if ($trayExists) {
        Write-AapTrayRunValue (Get-AapRunKey $userSid) $TrayExe
        [Console]::Out.WriteLine("DONE Run value AAP-Runner-Tray for $userSid (the tray starts at the next logon)")
    }
    [Console]::Out.WriteLine("DONE task $TaskName registered, not started. Start it with: Start-ScheduledTask $TaskName")
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Initialize-AapModulePath
        $code = 1
        Invoke-AapInstallSupervisor | ForEach-Object {
            if ($_ -is [int]) { $code = $_ } else { [Console]::Out.WriteLine([string]$_) }
        }
        exit $code
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
