# The guest agent (guest-transport.md): C:\Program Files\aap-guest\agent.ps1, Administrators-only, started by the fixed
# remote script of supervisor\backends\windows\psdirect-call.ps1 as
#   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\aap-guest\agent.ps1"
# Stdin: the envelope line, then exactly payload_bytes bytes. Stdout: one reply line and nothing else. No arguments.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$out = [Console]::OpenStandardOutput()
[Console]::SetOut([IO.TextWriter]::Null)
[Console]::SetError([IO.TextWriter]::Null)
Import-Module (Join-Path $PSScriptRoot 'AapGuestAgent.psm1')
exit (Invoke-AapGuestAgent -In ([Console]::OpenStandardInput()) -Out $out)
