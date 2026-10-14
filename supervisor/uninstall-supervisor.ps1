# Removes the aap-runner host supervisor. Elevated. Windows PowerShell 5.1
# and PowerShell 7.
#
# Stops and unregisters AAP-CRRR-Supervisor, removes the copied script and
# task XML from C:\wsl\aap-runner-supervisor, and removes the installing
# user's Run value AAP-Runner-Tray (HKEY_USERS\<SID>, see
# install-supervisor.ps1). A running tray is not stopped.
# Nothing is written under C:\ProgramData\aap-runner: inbox\ is
# user-writable, and this script runs elevated. The folder stays in place.
# Stopping the task kills the supervisor without a drain, so the distro keeps
# running until logoff or wsl.exe --terminate aap-runner.
# -DryRun prints the plan and changes nothing.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$DataDir = 'C:\ProgramData\aap-runner',
    [string]$ScriptDir = 'C:\wsl\aap-runner-supervisor',
    [string]$TaskName = 'AAP-CRRR-Supervisor'
)

$ErrorActionPreference = 'Stop'

function Test-AapElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# The tray autostarts from the installing user's Run key. This script runs
# elevated, so HKCU is the elevated token's hive. The value goes into
# HKEY_USERS\<SID> of the installing user instead, the same SID the task
# runs as. On Fresh the elevated and the desktop user are the same account,
# so both name the same hive.
function Get-AapRunKey([string]$UserSid) {
    return "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows\CurrentVersion\Run"
}

function Clear-AapTrayRunValue([string]$RunKey) {
    if (Get-ItemProperty -LiteralPath $RunKey -Name 'AAP-Runner-Tray' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -LiteralPath $RunKey -Name 'AAP-Runner-Tray'
    }
}

function Invoke-AapUninstallSupervisor {
    $elevated = Test-AapElevated
    if (-not $elevated -and -not $DryRun) {
        [Console]::Out.WriteLine('FAIL elevation required: run from an elevated PowerShell')
        return 1
    }
    $files = @((Join-Path $ScriptDir 'aap-runner-supervisor.ps1'), (Join-Path $ScriptDir 'aap-runner-supervisor-task.xml'))
    $runKey = Get-AapRunKey ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $note = 'NOTE the distro keeps running until logoff or: wsl.exe --terminate aap-runner'
    if ($DryRun) {
        if (-not $elevated) { [Console]::Out.WriteLine('INFO elevation not-admin (dry run)') }
        [Console]::Out.WriteLine("WOULD stop and unregister task $TaskName")
        foreach ($f in $files) { [Console]::Out.WriteLine("WOULD remove $f") }
        [Console]::Out.WriteLine("WOULD remove Run value AAP-Runner-Tray from $runKey")
        [Console]::Out.WriteLine("KEEP $DataDir (inbox, status.json, logs)")
        [Console]::Out.WriteLine($note)
        return 0
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $TaskName
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    Clear-AapTrayRunValue $runKey
    [Console]::Out.WriteLine("DONE $TaskName removed. Left in place: $DataDir (inbox, status.json, logs).")
    [Console]::Out.WriteLine($note)
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
        if ([string]::IsNullOrEmpty($machine)) { throw 'refusing: machine PSModulePath is empty' }
        $env:PSModulePath = $machine
        $code = 1
        Invoke-AapUninstallSupervisor | ForEach-Object {
            if ($_ -is [int]) { $code = $_ } else { [Console]::Out.WriteLine([string]$_) }
        }
        exit $code
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
