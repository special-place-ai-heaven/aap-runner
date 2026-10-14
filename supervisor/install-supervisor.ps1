# Installs the aap-runner host supervisor. Elevated, idempotent.
# Windows PowerShell 5.1 and PowerShell 7.
#
# Trust split (the task runs elevated, the tray does not):
# - C:\ProgramData\aap-runner: owner Administrators, SYSTEM and
#   Administrators full control, the installing user read and execute only,
#   inheritance from ProgramData cut (ProgramData lets Users create). The
#   supervisor writes status.json and logs\ here.
# - C:\ProgramData\aap-runner\inbox: the only place the installing user can
#   write. On the folder itself the user can create and delete files but not
#   folders, so no junction can be made in it; files get Modify. The tray
#   writes state.json, settings.json and tray.log there; the supervisor only
#   reads them.
# - inbox\jobs gets that same ACL. The tray writes one request file per
#   elevated action there. The supervisor does not read it.
# - Before any ACL or write the data folder and everything in it are
#   checked: no reparse point (junction, symlink) anywhere, and an
#   Administrators, SYSTEM or TrustedInstaller owner on everything outside
#   inbox\. A failed check refuses the install and says how to fix it.
# - inbox\state.json {"desired":"off"} is created only if absent, after the
#   checks and the ACLs.
# - aap-runner-supervisor.ps1 is copied to C:\wsl\aap-runner-supervisor.
#   C:\wsl is SYSTEM and Administrators only on Fresh (install-host.ps1 locks
#   it with lock-acl.ps1). The copy is refused unless the folder is owned by
#   Administrators with only SYSTEM and Administrators entries, and no
#   ancestor up to the drive root lets anyone else delete, re-permission or
#   take ownership of it.
# - Task AAP-CRRR-Supervisor from aap-runner-supervisor-task.xml: logon
#   trigger, this user's SID, InteractiveToken, the same verified path as
#   AAP-CRRR-Mount-Work-Disk. Logoff stops the runner by design: WSL
#   sessions belong to the logon session.
# - -TrayExe (default C:\TOOLS\git_runner\aap-runner-tray.exe), if the file
#   exists: Run value AAP-Runner-Tray = "<path>" for the installing user, so
#   the tray starts at logon. Missing exe = skipped with an INFO line. The
#   tray is not started.
# The task is not started. -DryRun prints the plan, runs the same checks,
# and changes nothing.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$DataDir = 'C:\ProgramData\aap-runner',
    [string]$ScriptDir = 'C:\wsl\aap-runner-supervisor',
    [string]$TaskName = 'AAP-CRRR-Supervisor',
    [string]$TrayExe = 'C:\TOOLS\git_runner\aap-runner-tray.exe',
    [switch]$EnsureRequestDir
)

$ErrorActionPreference = 'Stop'

# SYSTEM, Administrators, TrustedInstaller.
$AapAdminSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$AapPathPattern = '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+'

function Initialize-AapModulePath {
    $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    if ([string]::IsNullOrEmpty($machine)) {
        throw 'refusing: machine PSModulePath is empty'
    }
    $env:PSModulePath = $machine
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

function Get-AapAccessRule($Acl) {
    return @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
}

# Same rule as install-host.ps1: owner Administrators, every entry SYSTEM or
# Administrators.
function Test-AapAdminAcl([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
    if ($null -eq $owner -or $owner.Value -ne 'S-1-5-32-544') { return $false }
    $rules = Get-AapAccessRule $acl
    foreach ($ace in $rules) {
        if ($ace.IdentityReference.Value -ne 'S-1-5-18' -and $ace.IdentityReference.Value -ne 'S-1-5-32-544') { return $false }
    }
    return ($rules.Count -gt 0)
}

# Same rule as the tray: owner is SYSTEM, Administrators, or TrustedInstaller,
# and no other SID has write, append, delete, delete-child, write-DAC,
# write-owner, or generic write/all on the object itself. Inherit-only allows
# do not apply. Any ACE that is not plain allow or deny refuses. A null DACL
# grants everyone, so it refuses.
function Test-AapAdminDescriptor($Raw) {
    if ($null -eq $Raw -or $null -eq $Raw.Owner) { return $false }
    if ($AapAdminSids -notcontains $Raw.Owner.Value) { return $false }
    if ($null -eq $Raw.DiscretionaryAcl) { return $false }
    $bad = 0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
    foreach ($ace in $Raw.DiscretionaryAcl) {
        $type = [int]$ace.AceType
        if ($type -ne 0 -and $type -ne 1) { return $false }
        if ($type -ne 0) { continue }
        if (([int]$ace.AceFlags -band 8) -ne 0) { continue }
        $sid = $ace.SecurityIdentifier.Value
        if ($AapAdminSids -contains $sid) { continue }
        if (([int]$ace.AccessMask -band $bad) -ne 0) { return $false }
    }
    return $true
}

function Test-AapAdminOwned([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $attr = [int](New-Object IO.FileInfo $Path).Attributes
    if ($attr -eq -1 -or ($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    try {
        $acl = Get-Acl -LiteralPath $Path
        $raw = New-Object System.Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(), 0)
    } catch {
        return $false
    }
    return (Test-AapAdminDescriptor $raw)
}

# Rights that let a non-admin replace or re-permission a folder below: delete
# it, delete children, change its DACL, take ownership. Create rights are not
# counted; C:\ grants Authenticated Users "create folders" by default and that
# cannot replace an existing child. Inherit-only entries do not apply to the
# folder itself (they show up on the child, which the leaf check covers).
function Get-AapAncestorProblem([string]$Path) {
    $bad = [int]([Security.AccessControl.FileSystemRights]'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership') -bor 0x10000000
    $problems = New-Object System.Collections.Generic.List[string]
    $unreadable = New-Object System.Collections.Generic.List[string]
    $dir = Split-Path -Parent $Path
    while ($dir) {
        $acl = $null
        try { $acl = Get-Acl -LiteralPath $dir } catch { $unreadable.Add($dir) }
        if ($acl) {
            foreach ($ace in (Get-AapAccessRule $acl)) {
                if ($ace.AccessControlType -ne 'Allow') { continue }
                if (($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
                $sid = $ace.IdentityReference.Value
                if ($AapAdminSids -contains $sid) { continue }
                if (([int]$ace.FileSystemRights -band $bad) -ne 0) {
                    $problems.Add("$dir grants $sid $($ace.FileSystemRights)")
                }
            }
        }
        $dir = Split-Path -Parent $dir
    }
    return [pscustomobject]@{ Problems = $problems; Unreadable = $unreadable }
}

# Walks the data folder without following any reparse point. Everything
# outside inbox\ must have an admin owner; inbox\ children are the tray's own
# files and may be owned by the user.
function Get-AapDataDirProblem([string]$Path) {
    $problems = New-Object System.Collections.Generic.List[string]
    $unreadable = New-Object System.Collections.Generic.List[string]
    $inbox = Join-Path $Path 'inbox'
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Path, $true))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $p = $item[0]
        $checkOwner = $item[1]
        # Attributes are -1 for a missing path and keep ReparsePoint even for
        # a dangling junction.
        $attr = [int](New-Object IO.FileInfo $p).Attributes
        if ($attr -eq -1) { continue }
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            $problems.Add("reparse point $p; remove it without following it: cmd /c rmdir `"$p`" (folder) or cmd /c del `"$p`" (file), then rerun")
            continue
        }
        if ($checkOwner) {
            try {
                $owner = (Get-Acl -LiteralPath $p).GetOwner([Security.Principal.SecurityIdentifier])
                if ($null -eq $owner -or $AapAdminSids -notcontains $owner.Value) {
                    $problems.Add("owner $($owner.Value) on $p is not an admin; delete it or run: icacls `"$p`" /setowner *S-1-5-32-544")
                }
            } catch {
                $unreadable.Add($p)
                continue
            }
        }
        if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) {
            $children = $null
            try { $children = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction Stop) } catch { $unreadable.Add($p) }
            foreach ($c in @($children)) {
                if ($null -eq $c) { continue }
                $stack.Push(@($c.FullName, ($p -ne $inbox -and $checkOwner)))
            }
        }
    }
    return [pscustomobject]@{ Problems = $problems; Unreadable = $unreadable }
}

# The SID and path are checked before they go into XML and into the
# single-quoted -Command string of the task.
function Get-AapSupervisorTaskXml {
    param([string]$Template, [string]$UserSid, [string]$Ps1)
    if ($UserSid -notmatch '^S-1-5-21(-\d+){4}\z') { throw "refusing: user SID $UserSid" }
    if ($Ps1 -notmatch ($AapPathPattern + '\.ps1\z')) { throw "refusing: script path $Ps1" }
    $xml = $Template.Replace('__AAP_USER_SID__', $UserSid).Replace('__AAP_PS1__', $Ps1)
    if ($xml.Contains('__AAP_')) { throw 'task template still has a placeholder' }
    return $xml
}

# The tray autostarts from the installing user's Run key. This script runs
# elevated, so HKCU is the elevated token's hive. The value goes into
# HKEY_USERS\<SID> of the installing user instead, the same SID the task
# runs as. On Fresh the elevated and the desktop user are the same account,
# so both name the same hive.
function Get-AapRunKey([string]$UserSid) {
    return "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows\CurrentVersion\Run"
}

# Quoted, so a path with spaces starts the exe and not a prefix of it.
function Write-AapTrayRunValue([string]$RunKey, [string]$Exe) {
    if ($Exe -notmatch ($AapPathPattern + '\.exe\z')) { throw "refusing: tray path $Exe" }
    if (-not (Test-Path -LiteralPath $RunKey)) { New-Item -Path $RunKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $RunKey -Name 'AAP-Runner-Tray' -Value ('"' + $Exe + '"') -PropertyType String -Force | Out-Null
}

function Get-AapAllowRule([string]$Sid, $Rights, $Inherit, $Propagate) {
    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier $Sid), $Rights, $Inherit, $Propagate, 'Allow')
}

# Root: admins full, the user read and execute, everything inheriting.
function Get-AapDataDirAcl([string]$UserSid) {
    $all = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $acl.AddAccessRule((Get-AapAllowRule 'S-1-5-18' 'FullControl' $all $none))
    $acl.AddAccessRule((Get-AapAllowRule 'S-1-5-32-544' 'FullControl' $all $none))
    $acl.AddAccessRule((Get-AapAllowRule $UserSid 'ReadAndExecute' $all $none))
    return $acl
}

# Inbox: as the root, plus for the user create files and delete children on
# the folder itself (no CreateDirectories, so no subfolder or junction), and
# Modify on the files inside (inherit-only, files only).
function Get-AapInboxAcl([string]$UserSid) {
    $acl = Get-AapDataDirAcl $UserSid
    $folder = [Security.AccessControl.FileSystemRights]'ReadAndExecute, CreateFiles, DeleteSubdirectoriesAndFiles'
    $acl.AddAccessRule((Get-AapAllowRule $UserSid $folder ([Security.AccessControl.InheritanceFlags]::None) ([Security.AccessControl.PropagationFlags]::None)))
    $acl.AddAccessRule((Get-AapAllowRule $UserSid 'Modify' ([Security.AccessControl.InheritanceFlags]::ObjectInherit) ([Security.AccessControl.PropagationFlags]::InheritOnly)))
    return $acl
}

function Protect-AapDataDir([string]$Path, [string]$UserSid) {
    Set-Acl -LiteralPath $Path -AclObject (Get-AapDataDirAcl $UserSid)
    $inbox = Join-Path $Path 'inbox'
    Set-Acl -LiteralPath $inbox -AclObject (Get-AapInboxAcl $UserSid)
    $jobs = Join-Path $inbox 'jobs'
    if (Test-Path -LiteralPath $jobs) {
        $attr = [int](New-Object IO.FileInfo $jobs).Attributes
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "refusing: reparse point $jobs"
        }
        Set-Acl -LiteralPath $jobs -AclObject (Get-AapInboxAcl $UserSid)
    }
}

# Creates inbox\jobs so the non-elevated tray can write a request file.
# Same ACL as inbox: create files, not folders.
function Initialize-AapRequestDir([string]$Path, [string]$UserSid) {
    $inbox = Join-Path $Path 'inbox'
    $jobs = Join-Path $inbox 'jobs'
    foreach ($dir in @($Path, (Join-Path $Path 'logs'), $inbox, $jobs)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }
    foreach ($p in @($Path, $inbox, $jobs)) {
        $attr = [int](New-Object IO.FileInfo $p).Attributes
        if ($attr -eq -1 -or ($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "refusing: reparse point $p"
        }
    }
    $probe = Get-AapDataDirProblem $Path
    if ($probe.Problems.Count -or $probe.Unreadable.Count) {
        throw "refusing: $(@($probe.Problems) + @($probe.Unreadable) -join '; ')"
    }
    Protect-AapDataDir $Path $UserSid
}

function Register-AapTask([string]$Name, [string]$XmlFile) {
    & C:\Windows\System32\schtasks.exe /Create /TN $Name /XML $XmlFile /F
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create /TN $Name failed (exit $LASTEXITCODE)" }
}

function Get-AapSupervisorPlan {
    param([hashtable]$Facts)
    $lines = New-Object System.Collections.Generic.List[string]
    $failed = $false
    if ($Facts.Elevated) {
        $lines.Add('PASS elevation admin')
    } elseif ($Facts.DryRun) {
        $lines.Add('INFO elevation not-admin (dry run)')
    } else {
        $lines.Add('FAIL elevation required: run from an elevated PowerShell')
        $failed = $true
    }
    foreach ($p in @($Facts.DataProblems) + @($Facts.ScriptProblems)) {
        if (-not $p) { continue }
        $lines.Add("FAIL $p")
        $failed = $true
    }
    foreach ($u in @($Facts.Unreadable)) {
        if (-not $u) { continue }
        if ($Facts.DryRun) {
            $lines.Add("INFO cannot inspect $u without elevation")
        } else {
            $lines.Add("FAIL cannot inspect $u")
            $failed = $true
        }
    }
    if (-not $failed) {
        $lines.Add("PASS no reparse point or non-admin owner under $($Facts.DataDir)")
        $lines.Add("WOULD acl $($Facts.DataDir) and logs: owner Administrators; Administrators, SYSTEM full; $($Facts.UserSid) read; no inheritance")
        $lines.Add("WOULD acl $($Facts.DataDir)\inbox: as above plus $($Facts.UserSid) create and delete files (no folders), Modify on files")
        $lines.Add("WOULD acl $($Facts.DataDir)\inbox\jobs: same as inbox, for helper request files")
        if ($Facts.StateExists) {
            $lines.Add('SKIP inbox\state.json already present')
        } else {
            $lines.Add('WOULD inbox\state.json {"desired":"off"}')
        }
        $lines.Add("WOULD copy aap-runner-supervisor.ps1 to $($Facts.ScriptDir) (refused unless admin-only ACL)")
        $lines.Add("WOULD task $($Facts.TaskName) logon trigger, InteractiveToken")
        if ($Facts.TrayExists) {
            $lines.Add("WOULD run-key $(Get-AapRunKey $Facts.UserSid) AAP-Runner-Tray = `"$($Facts.TrayExe)`"")
        } else {
            $lines.Add("INFO tray $($Facts.TrayExe) not found; Run value skipped")
        }
        $lines.Add("UNDO: uninstall-supervisor.ps1")
        $lines.Add("NOTE the task is not started. Start it with: Start-ScheduledTask $($Facts.TaskName)")
        $lines.Add('NOTE desired is off by default. A running aap-runner distro is drained and terminated on first start unless inbox\state.json says on.')
    }
    $code = 0
    if ($failed) { $code = 1 }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

function Invoke-AapInstallSupervisor {
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $inbox = Join-Path $DataDir 'inbox'
    $stateFile = Join-Path $inbox 'state.json'
    $stateExists = $false
    try { $stateExists = [bool](Test-Path -LiteralPath $stateFile -ErrorAction Stop) } catch { $stateExists = $false }
    $trayExists = [bool](Test-Path -LiteralPath $TrayExe -PathType Leaf)
    $trayProblems = @()
    $script:trayAnc = [pscustomobject]@{ Problems = @(); Unreadable = @() }
    if ($trayExists) {
        if ($TrayExe -notmatch ($AapPathPattern + '\.exe\z')) { throw "refusing: tray path $TrayExe" }
        $trayDir = Split-Path -Parent $TrayExe
        if (-not (Test-AapAdminOwned $trayDir)) {
            $trayProblems += @("tray directory $trayDir is not admin-owned")
        }
        if (-not (Test-AapAdminOwned $TrayExe)) {
            $trayProblems += @("tray exe $TrayExe is not admin-owned")
        }
        $script:trayAnc = Get-AapAncestorProblem $TrayExe
    }
    $data = Get-AapDataDirProblem $DataDir
    $anc = Get-AapAncestorProblem $ScriptDir
    $plan = Get-AapSupervisorPlan @{
        Elevated       = (Test-AapElevated)
        DryRun         = [bool]$DryRun
        DataDir        = $DataDir
        ScriptDir      = $ScriptDir
        TaskName       = $TaskName
        UserSid        = $userSid
        StateExists    = $stateExists
        TrayExe        = $TrayExe
        TrayExists     = $trayExists
        DataProblems   = @($data.Problems) + @($trayProblems)
        ScriptProblems = @($anc.Problems) + @($script:trayAnc.Problems)
        Unreadable     = @($data.Unreadable) + @($anc.Unreadable) + @($script:trayAnc.Unreadable)
    }
    $template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'aap-runner-supervisor-task.xml')
    $ps1 = Join-Path $ScriptDir 'aap-runner-supervisor.ps1'
    # Rendered on a dry run too, so a bad SID or path fails before any change.
    $xml = Get-AapSupervisorTaskXml -Template $template -UserSid $userSid -Ps1 $ps1
    foreach ($line in $plan.Lines) { [Console]::Out.WriteLine($line) }
    if ($DryRun -or $plan.ExitCode -ne 0) { return [int]$plan.ExitCode }

    foreach ($dir in @($DataDir, (Join-Path $DataDir 'logs'), $inbox, (Join-Path $inbox 'jobs'))) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    # Again right before Set-Acl, which would follow a junction made since the
    # first check.
    $again = Get-AapDataDirProblem $DataDir
    if ($again.Problems.Count -or $again.Unreadable.Count) { throw "refusing: $DataDir changed during install: $(@($again.Problems) + @($again.Unreadable) -join '; ')" }
    Protect-AapDataDir $DataDir $userSid
    $again = Get-AapDataDirProblem $DataDir
    if ($again.Problems.Count -or $again.Unreadable.Count) { throw "refusing: $DataDir changed during install: $(@($again.Problems) + @($again.Unreadable) -join '; ')" }
    # CreateNew never opens an existing file or link.
    if (-not (Test-Path -LiteralPath $stateFile)) {
        $bytes = [Text.Encoding]::ASCII.GetBytes('{"desired":"off"}')
        $fs = [IO.File]::Open($stateFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $ScriptDir)) { New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null }
    if (-not (Test-AapAdminAcl $ScriptDir)) { throw "refusing: $ScriptDir is not owned by Administrators with SYSTEM and Administrators entries only" }
    $src = Join-Path $PSScriptRoot 'aap-runner-supervisor.ps1'
    Copy-Item -LiteralPath $src -Destination $ps1 -Force
    if ((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $ps1).Hash) { throw "copy of $ps1 does not match" }

    $xmlFile = Join-Path $ScriptDir 'aap-runner-supervisor-task.xml'
    # UTF-16 LE with BOM: schtasks /XML rejects UTF-8.
    [IO.File]::WriteAllText($xmlFile, $xml, [Text.Encoding]::Unicode)
    Register-AapTask $TaskName $xmlFile
    if ($trayExists) {
        Write-AapTrayRunValue (Get-AapRunKey $userSid) $TrayExe
        [Console]::Out.WriteLine("DONE Run value AAP-Runner-Tray for $userSid (the tray starts at the next logon)")
    }
    [Console]::Out.WriteLine("DONE task $TaskName registered, not started. Start it with: Start-ScheduledTask $TaskName")
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Initialize-AapModulePath
        if ($EnsureRequestDir) {
            if (-not (Test-AapElevated)) { throw 'refusing: elevation required' }
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Initialize-AapRequestDir $DataDir $sid
            [Console]::Out.WriteLine("DONE $DataDir\inbox\jobs")
            exit 0
        }
        $code = 1
        Invoke-AapInstallSupervisor | ForEach-Object {
            if ($_ -is [int]) { $code = $_ } else { [Console]::Out.WriteLine([string]$_) }
        }
        exit $code
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
