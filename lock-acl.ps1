# Leave only SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544) on a file
# or directory, and set the owner to Administrators. Bootstrap runs this
# from an elevated shell. Directories pass the two ACEs down to children.
# A leftover writer, or any other owner, fails the install.
# Get-Acl and Set-Acl work in Windows PowerShell 5.1 and PowerShell 7.
# FileInfo.GetAccessControl does not exist in PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LiteralPath
)
# powershell.exe 5.1 inherits pwsh 7's PSModulePath and then cannot autoload
# Microsoft.PowerShell.Security (Get-Acl CouldNotAutoload).
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
if ([string]::IsNullOrEmpty($env:PSModulePath)) {
    Write-Error 'refusing: machine PSModulePath is empty'
    exit 1
}
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $LiteralPath)) {
    Write-Error "path does not exist: $LiteralPath"
    exit 1
}
$allowed = @('S-1-5-18', 'S-1-5-32-544')
$adminsSid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
$item = Get-Item -LiteralPath $LiteralPath
$acl = Get-Acl -LiteralPath $LiteralPath
$acl.SetAccessRuleProtection($true, $false)
for ($i = 0; $i -lt 10 -and @($acl.Access).Count -gt 0; $i++) {
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }
}
if (@($acl.Access).Count -gt 0) {
    Write-Error "could not clear the DACL on $LiteralPath"
    exit 1
}
$inherit = [System.Security.AccessControl.InheritanceFlags]::None
$prop = [System.Security.AccessControl.PropagationFlags]::None
if ($item.PSIsContainer) {
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
}
foreach ($sidText in $allowed) {
    $sid = New-Object System.Security.Principal.SecurityIdentifier $sidText
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inherit,
        $prop,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
}
$acl.SetOwner($adminsSid)
Set-Acl -LiteralPath $LiteralPath -AclObject $acl

$check = Get-Acl -LiteralPath $LiteralPath
$ownerSid = $check.GetOwner([System.Security.Principal.SecurityIdentifier])
if ($null -eq $ownerSid -or $ownerSid.Value -ne 'S-1-5-32-544') {
    $shown = if ($null -eq $ownerSid) { 'missing' } else { $ownerSid.Value }
    Write-Error "owner of $LiteralPath is $shown; expected S-1-5-32-544"
    exit 1
}
$seen = @()
foreach ($rule in @($check.Access)) {
    $id = $rule.IdentityReference
    if ($id -is [System.Security.Principal.SecurityIdentifier]) {
        $sidValue = $id.Value
    } else {
        $sidValue = $id.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    if ($allowed -notcontains $sidValue) {
        Write-Error "unexpected ACE $sidValue on $LiteralPath"
        exit 1
    }
    if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
        Write-Error "non-allow ACE for $sidValue on $LiteralPath"
        exit 1
    }
    $seen += $sidValue
}
foreach ($need in $allowed) {
    if ($seen -notcontains $need) {
        Write-Error "missing ACE for $need on $LiteralPath"
        exit 1
    }
}
Write-Output "acl ok $LiteralPath owner=S-1-5-32-544"
