# Boot task. SYSTEM runs this once at startup. The only Windows path it
# operates on is the fixed VHDX. __AAP_VHDX__ is replaced at install.
$ErrorActionPreference = 'Stop'
$path = '__AAP_VHDX__'
$output = & wsl.exe --mount --vhd $path --bare 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) {
    exit 0
}
if ($output -match 'already') {
    exit 0
}
Write-Error $output
exit $LASTEXITCODE
