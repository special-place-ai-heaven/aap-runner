# Verify and repair for the elevated tray helper.
# Windows PowerShell 5.1 and PowerShell 7. Dot-source safe: no mandatory
# parameters, so tests can load the functions. A -File run checks the verb.
#
# -Fixture reads a ProgramData-shaped tree and changes nothing. It does not
# call wsl, schtasks, Set-Acl, or the install scripts. The elevated helper
# never passes -Fixture.
#
# Without -Fixture the only accepted -DataDir is C:\ProgramData\aap-runner.
# Every path below is a constant. Nothing is taken from a request file.
[CmdletBinding()]
param(
    [string]$Verb,
    [string]$DataDir = 'C:\ProgramData\aap-runner',
    [switch]$Fixture,
    [string]$TrayExe
)

$AapDataDir = 'C:\ProgramData\aap-runner'
$AapVhdx = 'C:\wsl\aap-runner-work.vhdx'
$AapSupervisorTask = 'AAP-CRRR-Supervisor'
$AapMountTask = 'AAP-CRRR-Mount-Work-Disk'
$AapPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$AapSchtasks = 'C:\Windows\System32\schtasks.exe'
$AapWsl = 'C:\Windows\System32\wsl.exe'

function Initialize-AapModulePath {
    $machine = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    if ([string]::IsNullOrEmpty($machine)) {
        throw 'refusing: machine PSModulePath is empty'
    }
    $env:PSModulePath = $machine
}

function Test-AapHelperDataDir([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path -match '\.\.') { return $false }
    return $Path -match '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+$'
}

function Test-AapHelperExe([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path -match '\.\.') { return $false }
    if ($Path.Contains('"')) { return $false }
    return $Path -match '^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.exe$'
}

function Test-AapReparsePoint([string]$Path) {
    $attr = [int](New-Object IO.FileInfo $Path).Attributes
    if ($attr -eq -1) { return $false }
    return (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Names reparse points and does not open them, so a planted junction is not followed.
function Get-AapReparseProblems([string]$Path) {
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return $problems }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $p = [string]$stack.Pop()
        $attr = [int](New-Object IO.FileInfo $p).Attributes
        if ($attr -eq -1) { continue }
        if (($attr -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            [void]$problems.Add($p)
            continue
        }
        if (($attr -band [int][IO.FileAttributes]::Directory) -ne 0) {
            foreach ($c in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
                if ($null -ne $c) { $stack.Push($c.FullName) }
            }
        }
    }
    return $problems
}

function Read-AapJsonBounded([string]$Path, [int]$Max) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (Test-AapReparsePoint $Path) { return $null }
    $len = (Get-Item -LiteralPath $Path -Force).Length
    if ($len -gt $Max) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ($text.Length -gt $Max) { return $null }
    try {
        $obj = $text | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    return $obj
}

function ConvertFrom-AapRfc3339([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    # TryParseExact's string[] overload is easy to miss from PowerShell, and ConvertFrom-Json
    # may turn the same text into a DateTime. Callers pass the raw JSON string.
    $styles = [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal'
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParse($Text, [cultureinfo]::InvariantCulture, $styles, [ref]$dt)
    if (-not $ok) { return $null }
    return $dt.ToUniversalTime()
}

# File checks only. Safe against a fixture tree: no wsl, schtasks, or ACL writes.
function Get-AapVerifyReport {
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [datetime]$Now = ([datetime]::UtcNow)
    )
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not (Test-AapHelperDataDir $DataDir)) {
        [void]$lines.Add('FAIL data-dir refused')
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) {
        [void]$lines.Add('FAIL data-dir missing')
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    if (Test-AapReparsePoint $DataDir) {
        [void]$lines.Add("FAIL reparse $DataDir")
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    [void]$lines.Add('PASS data-dir')
    $reparses = @(Get-AapReparseProblems $DataDir)
    if ($reparses.Count -gt 0) {
        [void]$lines.Add("FAIL reparse $($reparses[0])")
        return [pscustomobject]@{ ExitCode = 1; Lines = $lines }
    }
    [void]$lines.Add('PASS reparse none')
    $inbox = Join-Path $DataDir 'inbox'
    if ((Test-Path -LiteralPath $inbox -PathType Container) -and -not (Test-AapReparsePoint $inbox)) {
        [void]$lines.Add('PASS inbox')
    } else {
        [void]$lines.Add('FAIL inbox missing')
    }
    $state = Read-AapJsonBounded (Join-Path $inbox 'state.json') 4096
    if ($null -ne $state -and ($state.desired -eq 'on' -or $state.desired -eq 'off')) {
        [void]$lines.Add("PASS state $($state.desired)")
    } else {
        [void]$lines.Add('FAIL state missing or not on/off')
    }
    $settingsPath = Join-Path $inbox 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        [void]$lines.Add('PASS settings absent')
    } else {
        $settings = Read-AapJsonBounded $settingsPath 4096
        $count = $null
        if ($null -ne $settings) { $count = $settings.runner_count }
        if ($null -eq $settings) {
            [void]$lines.Add('FAIL settings unreadable')
        } elseif ($null -ne $count -and ($count -lt 1 -or $count -gt 5)) {
            [void]$lines.Add('FAIL settings runner_count')
        } else {
            [void]$lines.Add('PASS settings')
        }
    }
    $statusPath = Join-Path $DataDir 'status.json'
    $statusText = $null
    if ((Test-Path -LiteralPath $statusPath -PathType Leaf) -and -not (Test-AapReparsePoint $statusPath)) {
        $statusLen = (Get-Item -LiteralPath $statusPath -Force).Length
        if ($statusLen -le 65536) {
            $statusText = [IO.File]::ReadAllText($statusPath)
            if ($statusText.Length -gt 65536) { $statusText = $null }
        }
    }
    $status = $null
    if ($statusText) {
        try { $status = $statusText | ConvertFrom-Json } catch { $status = $null }
        if ($status -isnot [System.Management.Automation.PSCustomObject]) { $status = $null }
    }
    $known = @('off', 'starting', 'idle', 'running', 'draining', 'paused', 'error')
    if ($null -eq $status -or ($known -notcontains [string]$status.state)) {
        [void]$lines.Add('FAIL status missing or unknown state')
    } else {
        $schema = $status.schema
        if ($null -eq $schema -or $schema -eq 1 -or $schema -eq 2 -or $schema -eq 3 -or $schema -eq 4) {
            [void]$lines.Add("PASS status $($status.state)")
        } else {
            [void]$lines.Add("FAIL status schema $schema")
        }
    }
    $updated = $null
    if ($statusText -match '"updated"\s*:\s*"([^"]+)"') {
        $updated = ConvertFrom-AapRfc3339 $Matches[1]
    }
    if ($null -eq $updated) {
        [void]$lines.Add('FAIL supervisor-status missing updated')
    } else {
        $age = ($Now.ToUniversalTime() - $updated).TotalSeconds
        if ($age -ge 0 -and $age -le 180) {
            [void]$lines.Add('PASS supervisor-status fresh')
        } else {
            [void]$lines.Add("FAIL supervisor-status stale age=$([int]$age)s")
        }
    }
    $log = Join-Path (Join-Path $DataDir 'logs') 'supervisor.log'
    if ((Test-Path -LiteralPath $log -PathType Leaf) -and -not (Test-AapReparsePoint $log)) {
        [void]$lines.Add('PASS supervisor-log')
    } else {
        [void]$lines.Add('FAIL supervisor-log missing')
    }
    $code = 0
    foreach ($line in $lines) {
        if ($line.StartsWith('FAIL')) { $code = 1 }
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

# The repair actions and the only paths they use.
function Get-AapRepairPlan {
    return @(
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\aap-runner-work.vhdx' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\mount-work-vhdx.ps1' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\mount-work-vhdx-task.xml' }
        [pscustomobject]@{ Name = 'lock-acl'; Path = 'C:\wsl\aap-runner-supervisor' }
        [pscustomobject]@{ Name = 'install-supervisor'; Path = $AapDataDir }
        [pscustomobject]@{ Name = 'remount'; Path = $AapVhdx }
        [pscustomobject]@{ Name = 'restart-supervisor'; Path = $AapSupervisorTask }
    )
}

function Get-AapHelperLayout {
    $here = $PSScriptRoot
    if ([string]::IsNullOrEmpty($here)) { $here = (Get-Location).Path }
    $nested = Join-Path $here 'installer\install-host.ps1'
    if (Test-Path -LiteralPath $nested) {
        return [pscustomobject]@{
            Installer  = (Join-Path $here 'installer')
            Supervisor = (Join-Path $here 'supervisor')
        }
    }
    $parent = Split-Path -Parent $here
    return [pscustomobject]@{
        Installer  = $here
        Supervisor = (Join-Path $parent 'supervisor')
    }
}

function Format-AapProcessArg([string]$Arg) {
    if ($Arg.Contains('"')) { throw 'refusing: argument' }
    if ($Arg -match '\s') { return '"' + $Arg + '"' }
    return $Arg
}

# Streams stdout and stderr as the child runs. Returns the process exit code.
# The copy runs on CLR threads and writes to Console directly. A PowerShell
# scriptblock on those threads has no runspace, and pwsh 7 throws.
function Invoke-AapStreaming([string]$File, [string[]]$Arguments) {
    if (-not ('AapStream' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public static class AapStream {
    public static int Run(string file, string args) {
        var psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        psi.EnvironmentVariables["WSL_UTF8"] = "1";
        using (var proc = Process.Start(psi)) {
            var outThread = new Thread(delegate() { Copy(proc.StandardOutput); });
            var errThread = new Thread(delegate() { Copy(proc.StandardError); });
            outThread.Start();
            errThread.Start();
            proc.WaitForExit();
            outThread.Join();
            errThread.Join();
            return proc.ExitCode;
        }
    }
    static void Copy(StreamReader reader) {
        string line;
        while ((line = reader.ReadLine()) != null) {
            line = line.Replace("\0", "");
            if (line.Length > 2000) line = line.Substring(0, 2000);
            Console.Out.WriteLine(line);
        }
    }
}
'@
    }
    $quoted = @()
    foreach ($a in @($Arguments)) { $quoted += (Format-AapProcessArg $a) }
    return [int][AapStream]::Run($File, ($quoted -join ' '))
}

# /etc/aap-runner/manager.conf of the aap-runner distro, or $null when the
# distro is absent or wsl fails. One wsl call; the verify flow already enters
# the distro for the units check.
function Get-AapDistroManagerConf {
    if (-not (Test-Path -LiteralPath $AapWsl)) { return $null }
    # Windows PowerShell 5.1 turns merged native stderr into a terminating error under Stop.
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $AapWsl -d 'aap-runner' -u root -- /bin/cat /etc/aap-runner/manager.conf 2>&1 | ForEach-Object { "$_" } | Out-String
    } catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out -replace [char]0, '')
}

# Bytes of the fixed work VHDX, 0 when it is absent.
function Get-AapVhdxBytes {
    if (-not (Test-Path -LiteralPath $AapVhdx -PathType Leaf)) { return [long]0 }
    return [long](Get-Item -LiteralPath $AapVhdx -Force).Length
}

# AAP_WORK_DISK_GIB from the distro's manager.conf; without a distro the VHDX
# size rounded to GiB; 0 when neither is known (install-host keeps its default).
function Get-AapWorkDiskGiB {
    $conf = Get-AapDistroManagerConf
    if ($conf -and ($conf -match '(?m)^AAP_WORK_DISK_GIB=([0-9]+)\s*$')) { return [int]$Matches[1] }
    return [int][math]::Round((Get-AapVhdxBytes) / 1GB)
}

function Invoke-AapVerifyLive([string]$DataDir) {
    $layout = Get-AapHelperLayout
    $report = Get-AapVerifyReport -DataDir $DataDir
    foreach ($line in @($report.Lines)) { [Console]::Out.WriteLine([string]$line) }
    $failed = ($report.ExitCode -ne 0)
    [Console]::Out.WriteLine('STEP install-host -DryRun')
    $hostArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $layout.Installer 'install-host.ps1'), '-DryRun')
    $gib = Get-AapWorkDiskGiB
    if ($gib -gt 0) {
        [Console]::Out.WriteLine("INFO work-disk $gib GiB")
        $hostArgs += @('-WorkDiskGiB', "$gib")
    }
    $code = Invoke-AapStreaming $AapPs $hostArgs
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL install-host exit $code")
        $failed = $true
    } else {
        [Console]::Out.WriteLine('PASS install-host exit 0')
    }
    [Console]::Out.WriteLine('STEP install-supervisor -DryRun')
    $code = Invoke-AapStreaming $AapPs @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $layout.Supervisor 'install-supervisor.ps1'), '-DryRun')
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL install-supervisor exit $code")
        $failed = $true
    } else {
        [Console]::Out.WriteLine('PASS install-supervisor exit 0')
    }
    foreach ($task in @($AapSupervisorTask, $AapMountTask)) {
        [Console]::Out.WriteLine("STEP task $task")
        $code = Invoke-AapStreaming $AapSchtasks @('/Query', '/TN', $task, '/FO', 'LIST')
        if ($code -eq 0) {
            [Console]::Out.WriteLine("PASS task $task")
        } else {
            [Console]::Out.WriteLine("FAIL task $task missing")
            $failed = $true
        }
    }
    # The supervisor health check: both units active. Read-only; it does not restart them.
    [Console]::Out.WriteLine('STEP units')
    $code = Invoke-AapStreaming $AapWsl @(
        '-d', 'aap-runner', '-u', 'root', '--',
        '/bin/systemctl', 'is-active', 'sysbox', 'aap-runner-manager')
    if ($code -eq 0) {
        [Console]::Out.WriteLine('PASS units sysbox and aap-runner-manager')
    } else {
        [Console]::Out.WriteLine("FAIL units exit $code")
        $failed = $true
    }
    if ($failed) { return 1 }
    return 0
}

function Get-AapSupervisorTaskState {
    try {
        $task = Get-ScheduledTask -TaskName $AapSupervisorTask -ErrorAction Stop
    } catch {
        if ([string]$_.FullyQualifiedErrorId -match 'NotFound_TaskName') { return 'missing' }
        return 'unknown'
    }
    if ($null -eq $task) { return 'missing' }
    switch ([string]$task.State) {
        'Running' { return 'running' }
        'Queued' { return 'running' }
        'Ready' { return 'ready' }
        'Disabled' { return 'ready' }
        default { return 'unknown' }
    }
}

function Test-AapWslListHasDistro([string]$Text, [string]$Name) {
    $clean = $Text -replace [char]0, ''
    foreach ($line in ($clean -split "\r?\n")) {
        if ($line.Trim() -eq $Name) { return $true }
    }
    return $false
}

# 'running' when `wsl --list --running --quiet` names aap-runner. Listing only;
# this does not start the distro.
function Test-AapDistroListed {
    if (-not (Test-Path -LiteralPath $AapWsl)) { return 'unknown' }
    $out = & $AapWsl --list --running --quiet 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    if (Test-AapWslListHasDistro $out 'aap-runner') { return 'running' }
    return 'stopped'
}

# Missing, unreadable, or unparseable status refuses unless the supervisor task
# does not exist. A missing or older-than-180s "updated" is not trusted: the task
# state decides. starting, running, and draining refuse when the timestamp is fresh.
# A running aap-runner distro refuses even when the file says idle.
function Get-AapRepairRefusal([string]$DataDir, [datetime]$Now = ([datetime]::UtcNow)) {
    $busy = 'job running, repair refused; retry when idle or pause the runners first'
    $unread = 'status unreadable, repair refused; retry when idle or pause the runners first'
    if (-not (Test-AapHelperDataDir $DataDir)) { return $unread }
    $path = Join-Path $DataDir 'status.json'
    $text = $null
    try {
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-AapReparsePoint $path)) {
            $len = (Get-Item -LiteralPath $path -Force).Length
            if ($len -le 65536) {
                $text = [IO.File]::ReadAllText($path)
                if ($text.Length -gt 65536) { $text = $null }
            }
        }
    } catch {
        $text = $null
    }
    $state = $null
    if ($text -and ($text -match '"state"\s*:\s*"([^"]+)"')) { $state = $Matches[1] }
    $distro = Test-AapDistroListed
    if ($distro -eq 'running') { return $busy }
    if ($distro -eq 'unknown') { return $unread }
    if ([string]::IsNullOrEmpty($state)) {
        if ((Get-AapSupervisorTaskState) -eq 'missing') { return $null }
        return $unread
    }
    $fresh = $false
    $sawUpdated = $false
    if ($text -match '"updated"\s*:\s*"([^"]+)"') {
        $sawUpdated = $true
        $updated = ConvertFrom-AapRfc3339 $Matches[1]
        if ($null -ne $updated) {
            $age = ($Now.ToUniversalTime() - $updated).TotalSeconds
            if ($age -ge 0 -and $age -le 180) { $fresh = $true }
        }
    }
    if (-not $sawUpdated -or -not $fresh) {
        switch (Get-AapSupervisorTaskState) {
            'missing' { return $null }
            'ready' { return $null }
            'running' { return $busy }
            default { return $unread }
        }
    }
    if ($state -eq 'running' -or $state -eq 'draining' -or $state -eq 'starting') { return $busy }
    return $null
}

function Write-AapRepairRefusal {
    $refusal = Get-AapRepairRefusal $AapDataDir
    if ($refusal) {
        [Console]::Out.WriteLine("FAIL $refusal")
        return $true
    }
    return $false
}

function Invoke-AapRepairLive([string]$TrayExe) {
    if (Write-AapRepairRefusal) { return 1 }
    $layout = Get-AapHelperLayout
    foreach ($step in @(Get-AapRepairPlan)) {
        if ($step.Name -ne 'lock-acl') { continue }
        [Console]::Out.WriteLine("STEP lock-acl $($step.Path)")
        if (-not (Test-Path -LiteralPath $step.Path)) {
            [Console]::Out.WriteLine("SKIP lock-acl $($step.Path) absent")
            continue
        }
        if (Test-AapReparsePoint $step.Path) {
            [Console]::Out.WriteLine("FAIL lock-acl reparse $($step.Path)")
            return 1
        }
        $code = Invoke-AapStreaming $AapPs @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $layout.Installer 'lock-acl.ps1'), '-LiteralPath', $step.Path)
        if ($code -ne 0) {
            [Console]::Out.WriteLine("FAIL lock-acl $($step.Path) exit $code")
            return 1
        }
        [Console]::Out.WriteLine("PASS lock-acl $($step.Path)")
    }
    [Console]::Out.WriteLine('STEP install-supervisor')
    $supArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $layout.Supervisor 'install-supervisor.ps1'),
        '-DataDir', $AapDataDir)
    if ($TrayExe) { $supArgs += @('-TrayExe', $TrayExe) }
    $code = Invoke-AapStreaming $AapPs $supArgs
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL install-supervisor exit $code")
        return 1
    }
    [Console]::Out.WriteLine('PASS install-supervisor')
    if (Write-AapRepairRefusal) { return 1 }
    [Console]::Out.WriteLine('STEP remount')
    $installed = 'C:\wsl\mount-work-vhdx.ps1'
    $mountScript = $installed
    if (-not (Test-Path -LiteralPath $installed -PathType Leaf) -or (Test-AapReparsePoint $installed)) {
        $templatePath = Join-Path $layout.Installer 'mount-work-vhdx.ps1'
        $template = [IO.File]::ReadAllText($templatePath)
        if (-not $template.Contains('__AAP_VHDX__')) {
            [Console]::Out.WriteLine('FAIL remount template has no placeholder')
            return 1
        }
        $mountScript = Join-Path $layout.Installer 'mount-work-vhdx.running.ps1'
        $enc = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText($mountScript, $template.Replace('__AAP_VHDX__', $AapVhdx), $enc)
    }
    $code = Invoke-AapStreaming $AapPs @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $mountScript)
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL remount exit $code")
        return 1
    }
    [Console]::Out.WriteLine('PASS remount')
    if (Write-AapRepairRefusal) { return 1 }
    [Console]::Out.WriteLine("STEP restart $AapSupervisorTask")
    $end = Invoke-AapStreaming $AapSchtasks @('/End', '/TN', $AapSupervisorTask)
    if ($end -ne 0) {
        [Console]::Out.WriteLine("INFO restart end exit $end")
    }
    $code = Invoke-AapStreaming $AapSchtasks @('/Run', '/TN', $AapSupervisorTask)
    if ($code -ne 0) {
        [Console]::Out.WriteLine("FAIL restart exit $code")
        return 1
    }
    [Console]::Out.WriteLine("PASS restart $AapSupervisorTask")
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        Initialize-AapModulePath
        if ($Verb -ne 'verify' -and $Verb -ne 'repair') {
            [Console]::Error.WriteLine('refusing: verb')
            exit 2
        }
        if ($Fixture) {
            if ($Verb -eq 'repair') {
                [Console]::Out.WriteLine('FAIL repair fixture mode does not change the machine')
                exit 2
            }
            if (-not (Test-AapHelperDataDir $DataDir)) {
                [Console]::Error.WriteLine('refusing: DataDir')
                exit 2
            }
            $report = Get-AapVerifyReport -DataDir $DataDir
            foreach ($line in @($report.Lines)) { [Console]::Out.WriteLine([string]$line) }
            exit ([int]$report.ExitCode)
        }
        if ($DataDir -ne $AapDataDir) {
            [Console]::Error.WriteLine('refusing: DataDir')
            exit 2
        }
        if ($TrayExe -and -not (Test-AapHelperExe $TrayExe)) {
            [Console]::Error.WriteLine('refusing: TrayExe')
            exit 2
        }
        if ($Verb -eq 'verify') {
            exit (Invoke-AapVerifyLive -DataDir $DataDir)
        }
        exit (Invoke-AapRepairLive -TrayExe $TrayExe)
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
