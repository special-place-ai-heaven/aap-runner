# Compiler launcher for qualified zccache pairs (P13): powershell.exe ... -File zcshim.ps1 <compiler> [arguments]
# The exit code is the compiler's. Anything unqualified or failing runs the compiler directly.
# The arguments come from the process command line as Windows splits it, everything after this script's path: -File
# hands $args through PowerShell's parameter parsing, which splits -std:c++17, drops --% and -a:, and so on.
Import-Module (Join-Path $PSScriptRoot 'AapZcCache.psm1')
$all = [Environment]::GetCommandLineArgs()
$i = 1
while ($i -lt $all.Count -and $all[$i] -ne '-File') { $i++ }
$argv = $(if ($i + 1 -lt $all.Count) { @($all | Select-Object -Skip ($i + 2)) } else { @($args) })
exit (Invoke-AapZcShim -ConfigPath $env:AAP_ZC_STATE -InstallDir $PSScriptRoot -Argv $argv)
