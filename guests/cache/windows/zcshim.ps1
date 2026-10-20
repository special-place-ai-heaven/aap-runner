# Compiler launcher for qualified zccache pairs (P13): zcshim.ps1 <compiler> [arguments]
# The exit code is the compiler's. Anything unqualified or failing runs the compiler directly.
Import-Module (Join-Path $PSScriptRoot 'AapZcCache.psm1')
exit (Invoke-AapZcShim -ConfigPath $env:AAP_ZC_STATE -Argv $args)
