# One entry point for the aap-runner host install.
# Windows PowerShell 5.1 and PowerShell 7. The first action resets
# PSModulePath to the machine value so Get-Acl can autoload.
#
# wsl --import, --unregister, --unmount, --shutdown, and
# --mount --vhd --bare do not need elevation. The VHD opens as this
# user, who needs read/write on the file. Elevated and non-elevated
# processes of the same user SID share one WSL VM. Elevation matters
# for the ACL: C:\wsl and the VHDX are locked to SYSTEM and
# Administrators, so the attach and the logon task (HighestAvailable)
# run with an Administrators token.
#
# -DryRun is read-only and exits 0 when every check passed. Not being
# elevated is INFO on a dry run. -TestMode uses an unlocked VHDX under
# the user profile, skips the ACL lock and the boot task, and can run
# without elevation. -DistroName and -WorkVhdx override those paths.
# Group Policy AllowDiskMount = 0 blocks wsl --mount (HKLM\Software\Policies\WSL).
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$FreshInstall,
    [switch]$TestMode,
    [string]$DistroName,
    [string]$WorkVhdx,
    [string]$InstallDir,
    [string]$OperatorDistro = 'Ubuntu-24.04',
    [int]$WorkDiskGiB = 60,
    [string]$KeyPath
)

$ErrorActionPreference = 'Stop'

function Initialize-AapModulePath {
    $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    if ([string]::IsNullOrEmpty($machine)) {
        throw 'refusing: machine PSModulePath is empty'
    }
    $env:PSModulePath = $machine
}

function Test-AapName([string]$Name) {
    return $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

function Add-AapLine($Lines, [string]$Text) {
    [void]$Lines.Add($Text)
}

# Windows path text. Join-Path on PowerShell 7 for Linux requires the drive to exist.
function Join-AapWinPath([string]$Parent, [string]$Child) {
    return ($Parent.TrimEnd('\') + '\' + $Child)
}

# Absent and 1 match WSL IsFeatureAllowed (cf723c5): only DWORD 0 blocks.
function Get-AapAllowDiskMountLine([string]$Observed) {
    switch ($Observed) {
        '0' { return 'FAIL AllowDiskMount 0' }
        '1' { return 'PASS AllowDiskMount 1' }
        'absent' { return 'PASS AllowDiskMount absent' }
        default { return "WARN AllowDiskMount $Observed" }
    }
}

function Get-AapInstallPlan {
    param([hashtable]$Facts)
    $lines = New-Object System.Collections.Generic.List[string]
    $actions = New-Object System.Collections.Generic.List[string]
    $undo = New-Object System.Collections.Generic.List[string]
    $failed = $false
    $distro = [string]$Facts.DistroName
    $vhdx = [string]$Facts.WorkVhdx
    $parent = Split-Path -Parent $vhdx
    $install = [string]$Facts.InstallDir
    if (-not $install) { $install = Join-AapWinPath $parent $distro }

    if ($Facts.BashPreflightText) {
        Add-AapLine $lines ([string]$Facts.BashPreflightText).TrimEnd()
    }
    if ([int]$Facts.BashPreflightExit -ne 0) { $failed = $true }

    $policy = Get-AapAllowDiskMountLine ([string]$Facts.AllowDiskMount)
    Add-AapLine $lines $policy
    if ($policy.StartsWith('FAIL')) { $failed = $true }

    if (-not $Facts.Elevated) {
        Add-AapLine $lines 'INFO elevation not-admin'
        if (-not $Facts.DryRun -and -not $Facts.TestMode) {
            Add-AapLine $lines 'FAIL elevation required to lock C:\wsl and open the locked VHDX'
            $failed = $true
        }
    } else {
        Add-AapLine $lines 'PASS elevation admin'
    }

    foreach ($d in @($Facts.Denied)) {
        if (-not $d) { continue }
        if ($Facts.DryRun) {
            Add-AapLine $lines "INFO locked $d is not readable without elevation"
        } else {
            Add-AapLine $lines "FAIL locked $d is not readable without elevation"
            $failed = $true
        }
    }

    if (-not $failed -and $Facts.LeftoverExt4 -and -not $Facts.DistroRegistered) {
        Add-AapLine $lines "FAIL leftover $install\ext4.vhdx"
        $failed = $true
    }

    # The wizard can resume its own incomplete install, but must never turn the
    # upgrade-capable installer into a stop/reinstall operation on a live pool.
    if ($Facts.FreshInstall -and ($Facts.ManagerEnabled -or $Facts.ManagerActive -or
            ($Facts.InsideDone -and -not $Facts.StageCurrent))) {
        Add-AapLine $lines 'FAIL first-run install refuses an active/enabled manager or a staging upgrade; use the installed app'
        $failed = $true
    }

    $grand = Split-Path -Parent $parent
    $undoLock = "icacls `"$grand`" /restore `"$parent-acl-before.txt`""
    $undoStage = "Remove-Item -LiteralPath `"$(Join-AapWinPath $parent 'staging')`" -Recurse -Force"
    $undoVhdx = "Remove-Item -LiteralPath `"$vhdx`" -Force"
    $undoAttach = "wsl.exe --unmount `"$vhdx`""
    $undoFormat = "Remove-Item -LiteralPath `"$vhdx`" -Force"
    $undoImport = "wsl.exe --unregister $distro"
    $undoTask = 'schtasks.exe /Delete /TN AAP-CRRR-Mount-Work-Disk /F'
    $undoKey = "wsl.exe -d $distro -u root -- rm -f /etc/aap-runner/app.pem"
    $undoDisable = "wsl.exe -d $distro -u root -- systemctl enable aap-runner-manager"
    $undoUpgrade = 'no automatic undo, the previous files are overwritten. Re-run install-host.ps1 from the previous commit'

    if (-not $failed) {
        $needStage = $false
        if ($Facts.TestMode) {
            Add-AapLine $lines 'SKIP acl TestMode does not lock'
            Add-AapLine $lines 'SKIP task TestMode does not register a boot task'
        } else {
            if ($Facts.AclLocked) {
                Add-AapLine $lines 'SKIP acl already SYSTEM and Administrators'
            } else {
                $actions.Add('lock')
                $undo.Add($undoLock)
                Add-AapLine $lines 'WOULD lock'
                Add-AapLine $lines "UNDO lock: $undoLock"
                $needStage = $true
            }
            if ($Facts.TaskCurrent) {
                Add-AapLine $lines 'SKIP task xml hash matches'
            } else {
                $actions.Add('task')
                $undo.Add($undoTask)
                Add-AapLine $lines 'WOULD task'
                Add-AapLine $lines "UNDO task: $undoTask"
                $needStage = $true
            }
        }
        if ($Facts.VhdxExists) {
            Add-AapLine $lines 'SKIP create-vhdx already present'
        } else {
            $actions.Add('create-vhdx')
            $undo.Add($undoVhdx)
            Add-AapLine $lines 'WOULD create-vhdx'
            Add-AapLine $lines "UNDO create-vhdx: $undoVhdx"
            $needStage = $true
        }
        if ($Facts.DiskAttached) {
            Add-AapLine $lines 'SKIP attach already attached'
        } else {
            $actions.Add('attach')
            $undo.Add($undoAttach)
            Add-AapLine $lines 'WOULD attach'
            Add-AapLine $lines "UNDO attach: $undoAttach"
        }
        if ($Facts.InsideDone) {
            Add-AapLine $lines 'SKIP format work disk uuid already recorded'
        } else {
            $actions.Add('format')
            $undo.Add($undoFormat)
            Add-AapLine $lines 'WOULD format blkid -p -o export exit 2 only'
            Add-AapLine $lines "UNDO format: $undoFormat"
            $needStage = $true
        }
        if ($Facts.DistroRegistered) {
            Add-AapLine $lines "SKIP import distro $distro is registered"
        } else {
            $actions.Add('import')
            $undo.Add($undoImport)
            Add-AapLine $lines 'WOULD import'
            Add-AapLine $lines "UNDO import: $undoImport"
            $needStage = $true
        }
        if ($Facts.InsideDone) {
            Add-AapLine $lines 'SKIP inside install.done'
            if (-not $Facts.StageCurrent) {
                $actions.Add('upgrade')
                $undo.Add($undoUpgrade)
                Add-AapLine $lines 'WOULD upgrade staging.sha256 differs'
                Add-AapLine $lines "UNDO upgrade: $undoUpgrade"
                $needStage = $true
            }
        } else {
            $actions.Add('inside')
            $undo.Add($undoImport)
            Add-AapLine $lines 'WOULD inside manager disabled'
            Add-AapLine $lines "UNDO inside: $undoImport"
            $needStage = $true
        }
        if ($needStage) {
            # Copy and hash-check before any script runs. The lock action then
            # executes the checked lock-acl.ps1.
            $actions.Insert(0, 'stage')
            $undo.Insert(0, $undoStage)
            Add-AapLine $lines 'WOULD stage sha256'
            Add-AapLine $lines "UNDO stage: $undoStage"
        } else {
            Add-AapLine $lines 'SKIP stage current'
        }
        if ($Facts.ManagerEnabled) {
            $actions.Add('disable-manager')
            $undo.Add($undoDisable)
            Add-AapLine $lines 'WOULD disable-manager'
            Add-AapLine $lines "UNDO disable-manager: $undoDisable"
        } else {
            Add-AapLine $lines 'SKIP manager already disabled'
        }
        if ([string]$Facts.AppPem -eq 'ok') {
            Add-AapLine $lines 'SKIP p0 app.pem already root 0400'
            $actions.Add('p1')
            Add-AapLine $lines 'WOULD p1'
        } else {
            $actions.Add('p0')
            Add-AapLine $lines 'WOULD p0 app.pem absent is the only accepted FAIL'
            if ($Facts.KeyPath) {
                $actions.Add('key')
                $undo.Add($undoKey)
                Add-AapLine $lines 'WOULD key'
                Add-AapLine $lines "UNDO key: $undoKey"
                $actions.Add('p1')
                Add-AapLine $lines 'WOULD p1'
            }
        }
    }

    $code = 0
    if ($failed) { $code = 1 }
    return [pscustomobject]@{
        ExitCode = $code
        Lines    = $lines
        Actions  = $actions
        Undo     = $undo
    }
}

function Get-AapAllowDiskMountObserved {
    try {
        $key = 'HKLM:\Software\Policies\WSL'
        if (-not (Test-Path -LiteralPath $key)) { return 'absent' }
        $item = Get-ItemProperty -Path $key -Name AllowDiskMount -ErrorAction SilentlyContinue
        if ($null -eq $item -or $null -eq $item.AllowDiskMount) { return 'absent' }
        return [string][int]$item.AllowDiskMount
    } catch {
        return 'unreadable'
    }
}

function Test-AapElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# Test-Path throws on a path locked to SYSTEM and Administrators when the
# caller is not elevated. Returns $true, $false, or $null for denied.
function Test-AapPathQuiet([string]$Path) {
    try {
        return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Test-AapAdminAcl([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
    if ($null -eq $owner -or $owner.Value -ne 'S-1-5-32-544') { return $false }
    $any = $false
    foreach ($ace in @($acl.Access)) {
        $any = $true
        $id = $ace.IdentityReference
        if ($id -is [Security.Principal.SecurityIdentifier]) {
            $sid = $id.Value
        } else {
            $sid = $id.Translate([Security.Principal.SecurityIdentifier]).Value
        }
        if ($sid -ne 'S-1-5-18' -and $sid -ne 'S-1-5-32-544') { return $false }
    }
    return $any
}

function Invoke-AapChecked {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv)
    & $Argv[0] @($Argv | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) {
        throw "exit $LASTEXITCODE : $($Argv -join ' ')"
    }
}

function Get-AapWslPath {
    param([string]$Operator, [string]$WindowsPath)
    # -e: no shell, so the backslashes in the Windows path survive.
    $out = & wsl.exe -d $Operator -e /bin/wslpath -u $WindowsPath
    if ($LASTEXITCODE -ne 0 -or -not $out) { throw "wslpath failed for $WindowsPath" }
    return ([string]$out).Trim()
}

function Copy-AapLockedStaging {
    param([string]$SourceDir, [string]$DestDir, [string]$HashFile)
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    }
    foreach ($line in Get-Content -LiteralPath $HashFile) {
        if ($line -notmatch '^([0-9a-f]{64}) [ ]*(\S+)$') { continue }
        $want = $Matches[1]
        $name = $Matches[2]
        $src = Join-Path $SourceDir $name
        if (-not (Test-Path -LiteralPath $src)) { $src = Join-Path $PSScriptRoot $name }
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLower()
        if ($got -ne $want) { throw "source hash mismatch for $name" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $DestDir $name) -Force
    }
    # inside_packages records it as /etc/aap-runner/staging.sha256.
    Copy-Item -LiteralPath $HashFile -Destination (Join-Path $DestDir 'staging.sha256') -Force
    foreach ($line in Get-Content -LiteralPath $HashFile) {
        if ($line -notmatch '^([0-9a-f]{64}) [ ]*(\S+)$') { continue }
        $want = $Matches[1]
        $name = $Matches[2]
        $dest = Join-Path $DestDir $name
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower()
        if ($got -ne $want) { throw "staged hash mismatch for $name" }
    }
}

function Write-AapUndo {
    param([string]$Path, [string]$Line)
    if (-not (Test-Path -LiteralPath $Path)) {
        Set-Content -LiteralPath $Path -Encoding utf8 -Value '# Undo install-host.ps1. Run from the bottom.'
    }
    Add-Content -LiteralPath $Path -Encoding utf8 -Value $Line
}

function Invoke-AapHostExe {
    param([string[]]$Argv)
    $exe = (Get-Process -Id $PID).Path
    & $exe -NoProfile @Argv
    if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE : $($Argv -join ' ')" }
}

function Install-AapKeyFromStdin {
    param([string]$Distro, [string]$Path)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = "-d $Distro -u root -- /bin/sh -c `"umask 077; cat > /etc/aap-runner/app.pem; chown root:root /etc/aap-runner/app.pem; chmod 0400 /etc/aap-runner/app.pem`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $in = [System.IO.File]::OpenRead($Path)
    try {
        $in.CopyTo($proc.StandardInput.BaseStream)
    } finally {
        $in.Close()
        $proc.StandardInput.Close()
    }
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "key install failed (exit $($proc.ExitCode))" }
    $mode = & wsl.exe -d $Distro -u root -- /usr/bin/stat -c '%a:%u' /etc/aap-runner/app.pem
    if ($LASTEXITCODE -ne 0 -or ([string]$mode).Trim() -ne '400:0') {
        throw 'key is not root mode 0400'
    }
    Remove-Item -LiteralPath $Path -Force
}

function Invoke-AapEvidenceText {
    param([string]$Operator, [string]$Evidence, [string]$Distro)
    $prev = $env:AAP_RUNNER_DISTRO
    $env:AAP_RUNNER_DISTRO = $Distro
    try {
        $text = Invoke-AapQuiet { & wsl.exe -d $Operator -- /usr/bin/env "AAP_RUNNER_DISTRO=$Distro" /bin/bash $Evidence }
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
    } finally {
        if ($null -eq $prev) { Remove-Item Env:AAP_RUNNER_DISTRO -ErrorAction SilentlyContinue }
        else { $env:AAP_RUNNER_DISTRO = $prev }
    }
}

# Windows PowerShell 5.1 turns native stderr merged with 2>&1 into a
# terminating error when $ErrorActionPreference is Stop (Fresh: stat of an
# absent app.pem ended a non-admin dry run with exit 1 and no plan).
# $LASTEXITCODE is still the native exit code afterwards.
function Invoke-AapQuiet([scriptblock]$Block) {
    $ErrorActionPreference = 'Continue'
    return (& $Block 2>&1 | ForEach-Object { "$_" } | Out-String)
}

function Test-AapTaskHashMatch([string]$XmlPath, [string]$HashPath) {
    if (-not (Test-Path -LiteralPath $XmlPath) -or -not (Test-Path -LiteralPath $HashPath)) {
        return $false
    }
    $prev = ((Get-Content -LiteralPath $HashPath -Raw) -replace '\s', '').ToLower()
    $now = (Get-FileHash -Algorithm SHA256 -LiteralPath $XmlPath).Hash.ToLower()
    return $prev -eq $now
}

function Test-AapP0PemOnly([string]$Text) {
    $fails = @()
    foreach ($line in ($Text -split "`n")) {
        $trim = $line.Trim()
        if ($trim -match 'FAIL ') { $fails += $trim }
    }
    return ($fails.Count -eq 1 -and $fails[0] -match 'app\.pem is missing')
}

function Invoke-AapInstallHost {
    if (-not $DistroName) {
        if ($TestMode) { $script:DistroName = 'aap-runner-test' }
        else { $script:DistroName = 'aap-runner' }
    }
    if (-not $WorkVhdx) {
        if ($TestMode) {
            $script:WorkVhdx = Join-Path (Join-Path $env:USERPROFILE 'aap-runner-test') 'aap-runner-work.vhdx'
        } else {
            $script:WorkVhdx = 'C:\wsl\aap-runner-work.vhdx'
        }
    }
    if (-not (Test-AapName $DistroName)) { throw "refusing: DistroName $DistroName" }
    if ($WorkVhdx -notmatch '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.vhdx$') {
        throw "refusing: WorkVhdx $WorkVhdx"
    }
    if (-not $InstallDir) {
        if ($DistroName -eq 'aap-runner' -and -not $TestMode) {
            $script:InstallDir = 'C:\aap-runner'
        } else {
            $script:InstallDir = Join-Path (Split-Path -Parent $WorkVhdx) $DistroName
        }
    }

    # bootstrap.sh and staging.sha256 live in ..\distro; the Windows scripts live here.
    $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\distro')).Path
    $linuxRepo = Get-AapWslPath $OperatorDistro $repo
    $linuxVhdx = Get-AapWslPath $OperatorDistro $WorkVhdx
    $linuxInstall = Get-AapWslPath $OperatorDistro $InstallDir
    $parent = Split-Path -Parent $WorkVhdx
    $stageWin = Join-Path $parent 'staging'
    $linuxStage = Get-AapWslPath $OperatorDistro $stageWin
    $bootstrap = "$linuxRepo/bootstrap.sh"

    $pre = Invoke-AapQuiet {
        & wsl.exe -d $OperatorDistro -- /usr/bin/env `
        "AAP_RUNNER_DISTRO=$DistroName" `
        "AAP_WORK_VHDX=$linuxVhdx" `
        "AAP_WORK_DISK_GIB=$WorkDiskGiB" `
        "AAP_RUNNER_INSTALL_DIR=$linuxInstall" `
        "AAP_RUNNER_STAGE=$linuxStage" `
        /bin/bash $bootstrap --preflight
    }
    $preExit = $LASTEXITCODE
    $proof = ''
    foreach ($line in ($pre -split "`n")) {
        if ($line.Trim() -match '^PROOF (nat|absent)$') { $proof = $Matches[1] }
    }

    $registered = $false
    $list = Invoke-AapQuiet { & wsl.exe -l -q }
    $list = $list -replace [char]0, ''
    foreach ($line in ($list -split "`n")) {
        if ($line.Trim() -eq $DistroName) { $registered = $true }
    }
    $denied = New-Object System.Collections.Generic.List[string]
    $vhdxExists = Test-AapPathQuiet $WorkVhdx
    if ($null -eq $vhdxExists) { $denied.Add($WorkVhdx); $vhdxExists = $true }
    $aclLocked = $false
    if (-not $TestMode -and (Test-AapPathQuiet $parent)) {
        try { $aclLocked = Test-AapAdminAcl $parent } catch { $denied.Add("$parent acl") }
    }
    $taskCurrent = $false
    if (-not $TestMode) {
        & schtasks.exe /Query /TN AAP-CRRR-Mount-Work-Disk 1>$null 2>$null
        $queried = $LASTEXITCODE -eq 0
        $hashFile = Join-Path $parent 'mount-work-vhdx-task.xml.prev-hash'
        $xmlFile = Join-Path $parent 'mount-work-vhdx-task.xml'
        try {
            if ($queried -and (Test-AapTaskHashMatch $xmlFile $hashFile)) { $taskCurrent = $true }
            # The xml hash does not cover the logon script. A changed
            # mount-work-vhdx.ps1 must re-run the task step, which rewrites it.
            if ($taskCurrent) {
                $want = ((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'mount-work-vhdx.ps1')) -replace '__AAP_VHDX__', $WorkVhdx).TrimEnd()
                $have = (Get-Content -Raw -LiteralPath (Join-Path $parent 'mount-work-vhdx.ps1')).TrimEnd()
                if ($have -ne $want) { $taskCurrent = $false }
            }
        } catch { $denied.Add($xmlFile) }
    }
    $insideDone = $false
    # A distro without install.done gets the inside step, which stages anyway.
    $stageCurrent = $true
    $pem = 'absent'
    $managerOn = $false
    $managerActive = $false
    if ($registered) {
        & wsl.exe -d $DistroName -u root -- /bin/test -f /etc/aap-runner/install.done 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) { $insideDone = $true }
        if ($insideDone) {
            # A missing record (installed before it existed) counts as differs.
            $want = Get-Content -Raw -LiteralPath (Join-Path $repo 'staging.sha256')
            $have = Invoke-AapQuiet { & wsl.exe -d $DistroName -u root -- /bin/cat /etc/aap-runner/staging.sha256 }
            $stageCurrent = ($LASTEXITCODE -eq 0) -and (($have -replace '\s', '') -eq ($want -replace '\s', ''))
        }
        $mode = Invoke-AapQuiet { & wsl.exe -d $DistroName -u root -- /usr/bin/stat -c '%a:%u' /etc/aap-runner/app.pem }
        if ($LASTEXITCODE -eq 0 -and $mode.Trim() -eq '400:0') { $pem = 'ok' }
        $en = Invoke-AapQuiet { & wsl.exe -d $DistroName -u root -- /bin/systemctl is-enabled aap-runner-manager }
        if ($en -match '(?m)^enabled\s*$') { $managerOn = $true }
        if ($FreshInstall) {
            $active = Invoke-AapQuiet { & wsl.exe -d $DistroName -u root -- /bin/systemctl is-active aap-runner-manager }
            if ($active.Trim() -ne 'inactive') { $managerActive = $true }
        }
    }
    $attached = $pre -match 'PASS attached-disks work=/dev/'
    $leftover = (-not $registered) -and [bool](Test-AapPathQuiet (Join-Path $InstallDir 'ext4.vhdx'))

    $facts = @{
        DryRun            = [bool]$DryRun
        FreshInstall      = [bool]$FreshInstall
        TestMode          = [bool]$TestMode
        Elevated          = (Test-AapElevated)
        AllowDiskMount    = (Get-AapAllowDiskMountObserved)
        BashPreflightExit = $preExit
        BashPreflightText = $pre
        DistroName        = $DistroName
        WorkVhdx          = $WorkVhdx
        InstallDir        = $InstallDir
        VhdxExists        = $vhdxExists
        AclLocked         = $aclLocked
        TaskCurrent       = $taskCurrent
        DiskAttached      = [bool]$attached
        DistroRegistered  = $registered
        InsideDone        = $insideDone
        StageCurrent      = $stageCurrent
        AppPem            = $pem
        ManagerEnabled    = $managerOn
        ManagerActive     = $managerActive
        KeyPath           = $KeyPath
        LeftoverExt4      = [bool]$leftover
        Denied            = @($denied)
    }
    $plan = Get-AapInstallPlan -Facts $facts
    foreach ($line in $plan.Lines) { [Console]::Out.WriteLine($line) }
    if ($DryRun -or $plan.ExitCode -ne 0) { return [int]$plan.ExitCode }
    if (-not $proof -and ($plan.Actions -contains 'inside' -or $plan.Actions -contains 'upgrade')) {
        throw 'refusing: networking proof was not recorded'
    }

    $undoPath = Join-Path $parent 'UNDO.md'
    $hostExe = (Get-Process -Id $PID).Path
    $lockedBootstrap = "$linuxStage/bootstrap.sh"
    $i = 0
    foreach ($action in $plan.Actions) {
        $undoLine = $null
        if ($i -lt $plan.Undo.Count) { $undoLine = $plan.Undo[$i] }
        switch ($action) {
            'stage' {
                Copy-AapLockedStaging $repo $stageWin (Join-Path $repo 'staging.sha256')
                if (-not $TestMode) {
                    & $hostExe -NoProfile -File (Join-Path $stageWin 'lock-acl.ps1') -LiteralPath $stageWin
                    if ($LASTEXITCODE -ne 0) { throw "lock staging failed ($LASTEXITCODE)" }
                    Copy-AapLockedStaging $repo $stageWin (Join-Path $repo 'staging.sha256')
                }
            }
            'lock' {
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                }
                & icacls.exe $parent /save "$parent-acl-before.txt" | Out-Null
                & $hostExe -NoProfile -File (Join-Path $stageWin 'lock-acl.ps1') -LiteralPath $parent
                if ($LASTEXITCODE -ne 0) { throw "lock $parent failed ($LASTEXITCODE)" }
                Copy-AapLockedStaging $repo $stageWin (Join-Path $repo 'staging.sha256')
            }
            'create-vhdx' {
                $createArgs = @('-NoProfile', '-File', (Join-Path $stageWin 'create-work-vhdx.ps1'), '-Path', $WorkVhdx, '-SizeGiB', "$WorkDiskGiB")
                if ($TestMode) { $createArgs += '-SkipAcl' }
                & $hostExe @createArgs
                if ($LASTEXITCODE -ne 0) { throw "create vhdx failed ($LASTEXITCODE)" }
            }
            'task' {
                & wsl.exe -d $OperatorDistro -u root -- /usr/bin/env "AAP_RUNNER_DISTRO=$DistroName" "AAP_WORK_VHDX=$linuxVhdx" "AAP_WORK_DISK_GIB=$WorkDiskGiB" /bin/bash $lockedBootstrap --register-task
                if ($LASTEXITCODE -ne 0) { throw "register-task failed ($LASTEXITCODE)" }
            }
            'attach' {
                $mountOut = Invoke-AapQuiet { & wsl.exe --mount --vhd $WorkVhdx --bare }
                if ($LASTEXITCODE -ne 0 -and $mountOut -notmatch 'already' -and $mountOut -notmatch 'WSL_E_USER_VHD_ALREADY_ATTACHED') {
                    throw "wsl --mount --vhd failed ($LASTEXITCODE)"
                }
            }
            'format' {
                & wsl.exe -d $OperatorDistro -u root -- /usr/bin/env "AAP_RUNNER_DISTRO=$DistroName" "AAP_WORK_DISK_GIB=$WorkDiskGiB" "AAP_RUNNER_STAGE=$linuxStage" /bin/bash $lockedBootstrap --format-work-disk
                if ($LASTEXITCODE -ne 0) { throw "format failed ($LASTEXITCODE)" }
            }
            'import' {
                if (-not (Test-Path -LiteralPath $stageWin)) { throw 'staging directory is missing' }
                $tar = Get-ChildItem -LiteralPath $stageWin -Filter 'ubuntu-*-wsl.rootfs.tar.gz' | Select-Object -First 1
                if (-not $tar) {
                    & wsl.exe -d $OperatorDistro -u root -- /usr/bin/env "AAP_RUNNER_STAGE=$linuxStage" /bin/bash $lockedBootstrap --stage-downloads
                    if ($LASTEXITCODE -ne 0) { throw "stage-downloads failed ($LASTEXITCODE)" }
                    $tar = Get-ChildItem -LiteralPath $stageWin -Filter 'ubuntu-*-wsl.rootfs.tar.gz' | Select-Object -First 1
                }
                if (-not $tar) { throw 'rootfs tarball is missing after download' }
                if (-not (Test-Path -LiteralPath $InstallDir)) {
                    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
                }
                & wsl.exe --import $DistroName $InstallDir $tar.FullName --version 2
                if ($LASTEXITCODE -ne 0) { throw "wsl --import failed ($LASTEXITCODE)" }
            }
            { $_ -eq 'inside' -or $_ -eq 'upgrade' } {
                if ($action -eq 'upgrade') {
                    # Stopped and disabled like a first install; the boot after
                    # --terminate must not start it under --inside-runtime.
                    & wsl.exe -d $DistroName -u root -- /bin/systemctl disable --now aap-runner-manager
                    if ($LASTEXITCODE -ne 0) { throw 'could not stop the manager before the upgrade' }
                }
                & wsl.exe -d $DistroName -u root -- /bin/mkdir -p /var/lib/aap-runner/stage
                if ($LASTEXITCODE -ne 0) { throw 'mkdir stage inside the distro failed' }
                & wsl.exe -d $OperatorDistro -- /bin/tar -C $linuxStage -cf - . |
                    & wsl.exe -d $DistroName -u root -- /bin/tar -C /var/lib/aap-runner/stage -xf -
                if ($LASTEXITCODE -ne 0) { throw 'copy into the distro failed' }
                & wsl.exe -d $DistroName -u root -- /bin/bash /var/lib/aap-runner/stage/stage-into-distro.sh /var/lib/aap-runner/stage "$WorkDiskGiB"
                if ($LASTEXITCODE -ne 0) { throw 'inside-packages failed' }
                & wsl.exe --terminate $DistroName
                if ($LASTEXITCODE -ne 0) { throw 'wsl --terminate failed' }
                & wsl.exe -d $DistroName -u root -- /bin/bash /opt/aap-runner/bootstrap.sh --inside-runtime $proof
                if ($LASTEXITCODE -ne 0) { throw 'inside-runtime failed' }
            }
            'disable-manager' {
                & wsl.exe -d $DistroName -u root -- /bin/systemctl disable aap-runner-manager
                if ($LASTEXITCODE -ne 0) { throw 'could not disable the manager' }
            }
            'p0' {
                Copy-AapLockedStaging $repo $stageWin (Join-Path $repo 'staging.sha256')
                $ev = Invoke-AapEvidenceText $OperatorDistro "$linuxStage/evidence-host.sh" $DistroName
                if (-not (Test-AapP0PemOnly $ev.Text)) { throw 'P0 failed: app.pem absent was not the only FAIL' }
            }
            'key' {
                if (-not $KeyPath) { throw '-KeyPath is required for this step' }
                Install-AapKeyFromStdin $DistroName $KeyPath
            }
            'p1' {
                Copy-AapLockedStaging $repo $stageWin (Join-Path $repo 'staging.sha256')
                $ev = Invoke-AapEvidenceText $OperatorDistro "$linuxStage/evidence-host.sh" $DistroName
                if ($ev.Code -ne 0 -or $ev.Text -match 'FAIL ') { throw 'P1 evidence failed' }
                $en = Invoke-AapQuiet { & wsl.exe -d $DistroName -u root -- /bin/systemctl is-enabled aap-runner-manager }
                if ($en -match '(?m)^enabled\s*$') { throw 'manager is enabled after P1' }
                $active = Invoke-AapQuiet { & wsl.exe -d $DistroName -u root -- /bin/systemctl is-active aap-runner-manager }
                if ($active.Trim() -eq 'active') { throw 'manager is running after P1' }
            }
        }
        if ($undoLine -and $action -ne 'p0' -and $action -ne 'p1') {
            Write-AapUndo $undoPath "$action : $undoLine"
        }
        if ($action -eq 'stage' -or $action -eq 'lock' -or $action -eq 'create-vhdx' -or $action -eq 'task' -or $action -eq 'attach' -or $action -eq 'format' -or $action -eq 'import' -or $action -eq 'inside' -or $action -eq 'upgrade' -or $action -eq 'disable-manager' -or $action -eq 'key') {
            $i++
        }
    }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Initialize-AapModulePath
        # Only the [int] return is the exit code. Anything else the function
        # emits (native command output) is printed, never returned.
        $code = 1
        Invoke-AapInstallHost | ForEach-Object {
            if ($_ -is [int]) { $code = $_ } else { [Console]::Out.WriteLine([string]$_) }
        }
        exit $code
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
