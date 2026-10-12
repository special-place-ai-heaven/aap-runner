# Writes C: free gigabytes into the aap-runner distro.
# Scheduled Task AAP-CRRR-C-Free-GB runs this as SYSTEM. The distro cannot
# call Windows (interop is off), so Windows pushes the number in.
$ErrorActionPreference = 'Stop'
$disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
if ($null -eq $disk -or $null -eq $disk.Free) {
    exit 1
}
$gb = [math]::Floor($disk.Free / 1GB)
$epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($gb -notmatch '^\d+$' -or $epoch -notmatch '^\d+$') {
    exit 1
}
& wsl.exe -d aap-runner -u root -- /usr/local/sbin/aap-record-c-free-gb "$epoch" "$gb"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
