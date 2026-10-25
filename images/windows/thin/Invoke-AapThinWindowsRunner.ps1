<#
.SYNOPSIS
    Host-side bridge: waits for PowerShell Direct on the thin Windows VM, mints a
    GitHub runner registration token with gh and runs the guest installer in the VM.
.DESCRIPTION
    Run elevated on the Hyper-V host after the VM exists. Never changes VM settings,
    switches or guest services. The registration token and the admin password stay in
    memory only; output is limited to non-secret HOST|/WAIT| status lines.
#>
[CmdletBinding()]
param(
    [string]$VMName = 'aap-win-thin',
    [string]$LabRoot = 'E:/aap-runner/thin-vm',
    [string]$RepoUrl = 'https://github.com/special-place-ai-heaven/aap-runner',
    [Parameter(Mandatory = $true)][string]$GuestScript,
    [ValidateRange(1, 1440)][int]$SetupTimeoutMinutes = 45
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-HostStatus([string]$Message) { Write-Output "HOST|$Message" }
function Stop-Driver([string]$Message) {
    Write-Output "HOST|FAIL|$Message"
    exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-Driver 'must run elevated'
}

if ($RepoUrl -notmatch '^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
    Stop-Driver 'RepoUrl is not https://github.com/<owner>/<repo>'
}
$owner = $Matches[1]
$repo = $Matches[2]

if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) { Stop-Driver "VM '$VMName' not found" }
$passwordFile = Join-Path $LabRoot 'admin-password.txt'
if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) { Stop-Driver "password file missing: $passwordFile" }
if (-not (Test-Path -LiteralPath $GuestScript -PathType Leaf)) { Stop-Driver "guest script missing: $GuestScript" }
$GuestScript = (Resolve-Path -LiteralPath $GuestScript).ProviderPath
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Stop-Driver 'gh CLI not found on PATH' }

$plain = (Get-Content -LiteralPath $passwordFile -Raw).TrimEnd("`r", "`n")
if ([string]::IsNullOrEmpty($plain)) { Stop-Driver 'password file is empty' }
$credential = New-Object Management.Automation.PSCredential('Administrator', (ConvertTo-SecureString -String $plain -AsPlainText -Force))
$plain = $null

Write-HostStatus "waiting for PowerShell Direct on $VMName (timeout ${SetupTimeoutMinutes}m)"
$deadline = (Get-Date).AddMinutes($SetupTimeoutMinutes)
$nextWait = Get-Date
$guestName = $null
while ($true) {
    $probe = $null
    $remaining = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
    if ($remaining -le 0) { Stop-Driver "PowerShell Direct not ready after ${SetupTimeoutMinutes}m" }
    try {
        $probe = Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock { $env:COMPUTERNAME } -AsJob -ErrorAction Stop
        $finished = Wait-Job -Job $probe -Timeout ([Math]::Min(15, $remaining))
        if ($finished -and $probe.State -eq 'Completed') {
            $guestName = Receive-Job -Job $probe -ErrorAction Stop
            if ($guestName) { break }
        }
    } catch {
        # Setup is not ready; never echo remote diagnostics.
    } finally {
        if ($probe) {
            Stop-Job -Job $probe -ErrorAction SilentlyContinue
            Remove-Job -Job $probe -Force -ErrorAction SilentlyContinue
        }
    }
    $now = Get-Date
    if ($now -ge $deadline) { Stop-Driver "PowerShell Direct not ready after ${SetupTimeoutMinutes}m" }
    if ($now -ge $nextWait) {
        $state = (Get-VM -Name $VMName).State
        Write-Output ("WAIT|vm={0}|state={1}|remaining={2}m" -f $VMName, $state, [int]($deadline - $now).TotalMinutes)
        $nextWait = $now.AddMinutes(2)
    }
    Start-Sleep -Seconds ([Math]::Min(15, [Math]::Max(1, [int]($deadline - (Get-Date)).TotalSeconds)))
}
Write-HostStatus "PowerShell Direct ready (guest $guestName)"

# The answer ISO carries the setup password: eject it from this VM only, then delete it.
$labFull = [IO.Path]::GetFullPath($LabRoot).TrimEnd('\', '/') + '\'
foreach ($dvd in @(Get-VMDvdDrive -VMName $VMName)) {
    if ($dvd.Path -and [IO.Path]::GetFullPath($dvd.Path).StartsWith($labFull, [StringComparison]::OrdinalIgnoreCase)) {
        Set-VMDvdDrive -VMName $VMName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $null -ErrorAction Stop
        Write-HostStatus ("ejected lab media from DVD {0}:{1}" -f $dvd.ControllerNumber, $dvd.ControllerLocation)
    }
}
$left = @(Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($labFull, [StringComparison]::OrdinalIgnoreCase) })
if ($left.Count -gt 0) { Stop-Driver 'lab media still attached after eject' }
$answerIso = Join-Path $LabRoot 'autounattend.iso'
if (Test-Path -LiteralPath $answerIso) {
    Remove-Item -LiteralPath $answerIso -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $answerIso) { Stop-Driver 'answer ISO still present after delete' }
    Write-HostStatus 'answer ISO deleted'
} else {
    Write-HostStatus 'answer ISO already absent'
}

Write-HostStatus "requesting registration token for $owner/$repo"
$token = $null
$session = $null
try {
    # gh stdout is captured only into memory; stderr is dropped because it could echo response bodies.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $token = & gh api --method POST "repos/$owner/$repo/actions/runners/registration-token" --jq .token 2>$null
        $ghExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $token = (@($token) -join '').Trim()
    if ($ghExit -ne 0 -or $token -notmatch '^[A-Za-z0-9]{20,}$') {
        Stop-Driver "gh registration-token request failed (exit $ghExit)"
    }
    Write-HostStatus 'registration token obtained (not shown)'

    $session = New-PSSession -VMName $VMName -Credential $credential -ErrorAction Stop
    Write-HostStatus 'running guest installer via PowerShell Direct'
    $remoteFailed = $false
    $remoteErrors = $null
    Invoke-Command -Session $session -FilePath $GuestScript -ArgumentList $RepoUrl, $token, $VMName -ErrorAction Continue -ErrorVariable remoteErrors *> $null
    if ($remoteErrors) { $remoteFailed = $true }
    $guestExit = Invoke-Command -Session $session -ScriptBlock { $LASTEXITCODE } -ErrorAction Stop
    if ($remoteFailed) {
        Stop-Driver ("guest installer reported {0} error(s)" -f @($remoteErrors).Count)
    }
    if ($guestExit -and $guestExit -ne 0) { Stop-Driver "guest installer exited $guestExit" }
    Write-HostStatus 'guest installer succeeded'
} catch {
    Stop-Driver 'registration or guest installation failed; sensitive diagnostics suppressed'
} finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    $token = $null
    $credential = $null
}
Write-HostStatus 'done'
exit 0
