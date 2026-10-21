# The runner launcher: C:\Program Files\aap-guest\launch.ps1, started once per boot by start_runner as the scheduled task
# aap-guest-runner (the job user, S4U, highest privileges, normal priority), so it runs in a fresh logon environment
# and outside the PowerShell Direct session. Starts the per-job cache and Runner.Listener, waits for its one job and
# records the outcome in <ProgramData>\aap-guest\launch.json. No arguments, no output.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'AapGuestAgent.psm1')
$ctx = New-AapGuestContext
$started = Start-AapGuestRunner -Ctx $ctx
if ($null -eq $started) { exit 1 }
Wait-AapGuestRunner -Ctx $ctx -Started $started
exit 0
