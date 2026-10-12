# Leave only SYSTEM (S-1-5-18) and Administrators (S-1-5-32-544) on a file
# or directory. Bootstrap runs this from an elevated shell. Directories
# pass the two ACEs down to children. A leftover writer fails the install.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LiteralPath
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $LiteralPath)) {
    Write-Error "path does not exist: $LiteralPath"
    exit 1
}
$allowed = @('S-1-5-18', 'S-1-5-32-544')
$item = Get-Item -LiteralPath $LiteralPath
$acl = $item.GetAccessControl('Access')
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
$item.SetAccessControl($acl)

$check = (Get-Item -LiteralPath $LiteralPath).GetAccessControl('Access')
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
Write-Output "acl ok $LiteralPath"
