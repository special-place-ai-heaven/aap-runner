# Removes the aap-runner host supervisor. Elevated. Windows PowerShell 5.1
# and PowerShell 7.
#
# Writes {"desired":"off"}, stops and unregisters AAP-CRRR-Supervisor, and
# removes the copied script and task XML from C:\aap-runner\windows, and
# removes the installing user's Run value AAP-Runner-Tray (HKEY_USERS\<SID>,
# see install-supervisor.ps1). A running tray is not stopped.
# C:\ProgramData\aap-runner (state.json, status.json, logs) stays in place.
# Stopping the task kills the supervisor without a drain, so the distro is
# left as it is: stop it with wsl.exe --terminate aap-runner when idle.
# -DryRun prints the plan and changes nothing.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$DataDir = 'C:\ProgramData\aap-runner',
    [string]$ScriptDir = 'C:\aap-runner\windows',
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
    $stateFile = Join-Path $DataDir 'state.json'
    $runKey = Get-AapRunKey ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    if ($DryRun) {
        if (-not $elevated) { [Console]::Out.WriteLine('INFO elevation not-admin (dry run)') }
        [Console]::Out.WriteLine("WOULD write {`"desired`":`"off`"} to $stateFile")
        [Console]::Out.WriteLine("WOULD stop and unregister task $TaskName")
        foreach ($f in $files) { [Console]::Out.WriteLine("WOULD remove $f") }
        [Console]::Out.WriteLine("WOULD remove Run value AAP-Runner-Tray from $runKey")
        [Console]::Out.WriteLine("KEEP $DataDir (state.json, status.json, logs)")
        return 0
    }
    if (Test-Path -LiteralPath $DataDir) {
        $tmp = "$stateFile.tmp"
        [IO.File]::WriteAllText($tmp, '{"desired":"off"}', (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $stateFile -Force
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
    [Console]::Out.WriteLine("DONE $TaskName removed. Left in place: $DataDir (state.json, status.json, logs).")
    [Console]::Out.WriteLine('NOTE the distro was not stopped. When it is idle: wsl.exe --terminate aap-runner')
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
