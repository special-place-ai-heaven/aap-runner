# Dry-run plan checks. Dot-sources install-host.ps1 and writes nothing.
# Windows PowerShell 5.1 and PowerShell 7. No Pester.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'install-host.ps1')

function Assert-Aap([bool]$Cond, [string]$Message) {
    if (-not $Cond) { throw $Message }
}

function Get-AapBaseFacts([hashtable]$Extra) {
    $facts = @{
        DryRun            = $true
        TestMode          = $false
        Elevated          = $false
        AllowDiskMount    = 'absent'
        BashPreflightExit = 0
        BashPreflightText = "PASS operator distro=Ubuntu-24.04 user=operator`nPROOF nat"
        DistroName        = 'aap-runner'
        WorkVhdx          = 'C:\wsl\aap-runner-work.vhdx'
        InstallDir        = 'C:\aap-runner'
        VhdxExists        = $false
        AclLocked         = $false
        TaskCurrent       = $false
        DiskAttached      = $false
        DistroRegistered  = $false
        InsideDone        = $false
        StageCurrent      = $true
        AppPem            = 'absent'
        ManagerEnabled    = $false
        KeyPath           = ''
        LeftoverExt4      = $false
    }
    foreach ($key in @($Extra.Keys)) { $facts[$key] = $Extra[$key] }
    return $facts
}

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{})
$text = $plan.Lines -join "`n"
Assert-Aap ($plan.ExitCode -eq 0) "dry-run exit $($plan.ExitCode)"
Assert-Aap ($text -match 'INFO elevation not-admin') 'dry-run did not report INFO elevation'
Assert-Aap ($text -match 'PASS AllowDiskMount absent') 'dry-run did not pass an absent AllowDiskMount'
Assert-Aap ($plan.Actions[0] -eq 'stage') 'stage is not the first action'
Assert-Aap ($plan.Actions -contains 'lock') 'dry-run omitted the ACL lock'
Assert-Aap ($plan.Actions -contains 'task') 'dry-run omitted the boot task'
Assert-Aap ($text -match 'UNDO import: wsl.exe --unregister aap-runner') 'import undo is not unregister'
Assert-Aap ($text -notmatch 'systemctl start') 'dry-run starts the manager'
Assert-Aap (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'UNDO.md'))) 'plan wrote UNDO.md'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{ AllowDiskMount = '0'; Elevated = $true })
Assert-Aap ($plan.ExitCode -eq 1) 'AllowDiskMount 0 did not fail'
Assert-Aap ($plan.Actions.Count -eq 0) 'a failed plan still has actions'
Assert-Aap (($plan.Lines -join "`n") -match 'FAIL AllowDiskMount 0') 'missing AllowDiskMount 0 line'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{
        TestMode   = $true
        DryRun     = $true
        Elevated   = $false
        DistroName = 'aap-runner-test'
        WorkVhdx   = 'C:\Users\operator\aap-runner-test\aap-runner-work.vhdx'
        InstallDir = 'C:\Users\operator\aap-runner-test\aap-runner-test'
    })
$text = $plan.Lines -join "`n"
Assert-Aap ($plan.ExitCode -eq 0) "TestMode dry-run exit $($plan.ExitCode)"
Assert-Aap ($plan.Actions -notcontains 'lock') 'TestMode locks the ACL'
Assert-Aap ($plan.Actions -notcontains 'task') 'TestMode registers a boot task'
Assert-Aap ($plan.Actions -contains 'import') 'TestMode skipped import'
Assert-Aap ($plan.Actions -contains 'attach') 'TestMode skipped attach'
Assert-Aap ($plan.Actions[0] -eq 'stage') 'TestMode did not stage first'
Assert-Aap ($text -match 'SKIP acl TestMode') 'missing TestMode acl skip'
Assert-Aap ($text -match 'SKIP task TestMode') 'missing TestMode task skip'
Assert-Aap ($text -match 'UNDO import: wsl.exe --unregister aap-runner-test') 'TestMode undo used the wrong distro'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{
        DryRun           = $false
        Elevated         = $true
        DistroRegistered = $true
        VhdxExists       = $true
        AclLocked        = $true
        TaskCurrent      = $true
        DiskAttached     = $true
        InsideDone       = $true
        AppPem           = 'absent'
    })
$text = $plan.Lines -join "`n"
Assert-Aap ($plan.ExitCode -eq 0) "re-run exit $($plan.ExitCode)"
Assert-Aap ($plan.Actions -notcontains 'import') 're-run imports again'
Assert-Aap ($plan.Actions -notcontains 'lock') 're-run locks again'
Assert-Aap ($plan.Actions -notcontains 'task') 're-run registers the task again'
Assert-Aap ($text -match 'SKIP import distro aap-runner is registered') 'missing skip import'
Assert-Aap ($text -notmatch 'Unregister only this distro') 're-run requires an unregister'
Assert-Aap ($plan.Actions -contains 'p0') 're-run skipped P0'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{ DryRun = $false; Elevated = $false; TestMode = $false })
Assert-Aap ($plan.ExitCode -eq 1) 'a real run without elevation exited 0'
Assert-Aap (($plan.Lines -join "`n") -match 'FAIL elevation') 'missing elevation failure'
Assert-Aap ($plan.Actions.Count -eq 0) 'a non-admin real run still has actions'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{ DryRun = $false; Elevated = $false; TestMode = $true })
Assert-Aap ($plan.ExitCode -eq 0) 'TestMode without elevation failed'
Assert-Aap ($plan.Actions -contains 'import') 'TestMode without elevation skipped the install'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{
        Elevated          = $true
        DryRun            = $true
        BashPreflightExit = 1
        BashPreflightText = 'FAIL attached-disks /dev/sdd=697932185600'
    })
Assert-Aap ($plan.ExitCode -eq 1) 'a foreign disk preflight was accepted'
Assert-Aap ($plan.Actions.Count -eq 0) 'a foreign disk still scheduled mkfs'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{
        Elevated   = $true
        DryRun     = $false
        KeyPath    = 'C:\keys\app.pem'
        InsideDone = $true
        VhdxExists = $true
        AclLocked  = $true
        TaskCurrent = $true
        DiskAttached = $true
        DistroRegistered = $true
    })
Assert-Aap ($plan.Actions -contains 'p0') 'key install skipped P0'
Assert-Aap ($plan.Actions -contains 'key') 'key install omitted the key step'
Assert-Aap ($plan.Actions -contains 'p1') 'key install skipped P1'
Assert-Aap ($plan.Actions -notcontains 'disable-manager') 'a disabled manager was started'
Assert-Aap (($plan.Lines -join "`n") -notmatch 'systemctl start') 'key plan starts the manager'

$installed = @{
    DryRun           = $false
    Elevated         = $true
    DistroRegistered = $true
    VhdxExists       = $true
    AclLocked        = $true
    TaskCurrent      = $true
    DiskAttached     = $true
    InsideDone       = $true
    AppPem           = 'ok'
}
$plan = Get-AapInstallPlan (Get-AapBaseFacts $installed)
$text = $plan.Lines -join "`n"
Assert-Aap ($plan.Actions -notcontains 'upgrade') 'a current stage planned an upgrade'
Assert-Aap ($plan.Actions -notcontains 'stage') 'a current stage was staged again'
Assert-Aap ($text -match 'SKIP stage current') 'missing SKIP stage current'
$installed.StageCurrent = $false
$plan = Get-AapInstallPlan (Get-AapBaseFacts $installed)
$text = $plan.Lines -join "`n"
Assert-Aap ($plan.ExitCode -eq 0) "upgrade exit $($plan.ExitCode)"
Assert-Aap ($plan.Actions[0] -eq 'stage') 'upgrade did not stage first'
Assert-Aap ($plan.Actions -contains 'upgrade') 'a changed stage did not plan an upgrade'
Assert-Aap ($plan.Actions -notcontains 'inside') 'upgrade re-ran the first-install inside step'
Assert-Aap ($plan.Undo.Count -eq 2 -and $plan.Undo[1] -match 'no automatic undo') 'upgrade undo is not aligned or not explained'
Assert-Aap ($text -match 'WOULD upgrade staging.sha256 differs') 'missing WOULD upgrade line'
Assert-Aap ($text -match 'UNDO upgrade: no automatic undo.*previous commit') 'missing upgrade UNDO line'
Assert-Aap ($text -notmatch 'systemctl start') 'upgrade plan starts the manager'
$plan = Get-AapInstallPlan (Get-AapBaseFacts @{ StageCurrent = $false })
Assert-Aap ($plan.Actions -notcontains 'upgrade') 'a fresh install planned an upgrade'
Assert-Aap ($plan.Actions -contains 'inside') 'a fresh install skipped inside'

foreach ($unsafe in @(
    @{ FreshInstall = $true; ManagerEnabled = $true },
    @{ FreshInstall = $true; ManagerActive = $true },
    @{ FreshInstall = $true; InsideDone = $true; StageCurrent = $false }
)) {
    $plan = Get-AapInstallPlan (Get-AapBaseFacts $unsafe)
    Assert-Aap ($plan.ExitCode -eq 1) 'first-run install accepted an existing manager or upgrade'
    Assert-Aap ($plan.Actions.Count -eq 0) 'first-run refusal retained destructive actions'
}
$plan = Get-AapInstallPlan (Get-AapBaseFacts @{ FreshInstall = $true })
Assert-Aap ($plan.ExitCode -eq 0 -and $plan.Actions -contains 'inside') 'fresh first-run install was refused'

Assert-Aap ((Get-AapAllowDiskMountLine 'absent') -eq 'PASS AllowDiskMount absent') 'absent policy'
Assert-Aap ((Get-AapAllowDiskMountLine '0') -eq 'FAIL AllowDiskMount 0') 'zero policy'
Assert-Aap ((Get-AapAllowDiskMountLine '1') -eq 'PASS AllowDiskMount 1') 'one policy'

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('aap-task-hash-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
    $xml = Join-Path $dir 'mount-work-vhdx-task.xml'
    $hash = Join-Path $dir 'mount-work-vhdx-task.xml.prev-hash'
    Set-Content -LiteralPath $xml -Encoding ascii -Value '<Task/>'
    $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $xml).Hash.ToLower()
    Set-Content -LiteralPath $hash -Encoding ascii -Value $digest
    Assert-Aap (Test-AapTaskHashMatch $xml $hash) 'matching task xml hash was refused'
    Set-Content -LiteralPath $hash -Encoding ascii -Value ('a' * 64)
    Assert-Aap (-not (Test-AapTaskHashMatch $xml $hash)) 'a different task xml hash matched'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force
}

$src = Get-Content -Raw (Join-Path $PSScriptRoot 'install-host.ps1')
$dryAt = $src.IndexOf('if ($DryRun -or $plan.ExitCode -ne 0)')
$undoAt = $src.LastIndexOf('Write-AapUndo')
Assert-Aap ($dryAt -ge 0 -and $undoAt -gt $dryAt) 'DryRun can reach Write-AapUndo'
$upgradeAt = $src.IndexOf('disable --now aap-runner-manager')
Assert-Aap ($upgradeAt -gt $dryAt) 'DryRun can reach the upgrade step'
Assert-Aap ($src.Contains("GetEnvironmentVariable('PSModulePath', 'Machine')")) 'PSModulePath reset is missing'
$tail = $src.Substring($src.LastIndexOf('InvocationName'))
Assert-Aap ($tail.Contains('Initialize-AapModulePath') -and $tail.IndexOf('Initialize-AapModulePath') -lt $tail.IndexOf('Invoke-AapInstallHost')) 'module path is reset after the install starts'

$plan = Get-AapInstallPlan (Get-AapBaseFacts @{ Denied = @('C:\wsl\aap-runner-work.vhdx') })
Assert-Aap ($plan.ExitCode -eq 0) 'a locked VHDX failed a non-admin dry run'
Assert-Aap (($plan.Lines -join "`n") -match 'INFO locked C:\\wsl') 'a locked VHDX was not reported on a dry run'
$plan = Get-AapInstallPlan (Get-AapBaseFacts @{ DryRun = $false; Elevated = $true; Denied = @('C:\wsl\aap-runner-work.vhdx') })
Assert-Aap ($plan.ExitCode -eq 1) 'a real run accepted an unreadable VHDX'
Assert-Aap ($plan.Actions.Count -eq 0) 'an unreadable VHDX still has actions'
Assert-Aap (-not $tail.Contains('exit (Invoke-AapInstallHost)')) 'plan lines are swallowed into the exit code'
Assert-Aap (-not $src.Contains('-- /bin/wslpath')) 'wslpath runs through a shell that strips backslashes'

Assert-Aap (-not $src.Contains('2>&1 | Out-String')) 'native stderr merged under Stop ends a PS 5.1 run'
$q = Invoke-AapQuiet { & cmd.exe /d /c 'echo out & echo err 1>&2 & exit 3' }
Assert-Aap ($LASTEXITCODE -eq 3 -and $q -match 'out' -and $q -match 'err') "Invoke-AapQuiet lost output or exit code: $LASTEXITCODE $q"

Write-Output 'install-host dry-run tests ok'
exit 0
