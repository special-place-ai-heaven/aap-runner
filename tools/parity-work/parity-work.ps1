# Entry point for the parity worktree/lease/cleanup gate. See docs/parity/WORKTREES.md.
#   parity-work.ps1 <verb> -Name value ...
# Verbs: init, import, status, claim, transition, hold, clear-hold, add-dir, add-worktree,
# register-process, register-vm, register-asset, record-merge, cleanup, verify-cleanup.
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('init', 'import', 'status', 'claim', 'transition', 'hold', 'clear-hold', 'add-dir', 'add-worktree',
        'register-process', 'register-vm', 'register-asset', 'record-merge', 'cleanup', 'verify-cleanup')]
    [string]$Verb,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ParityWork.psm1') -Force

$named = @{}
for ($i = 0; $i -lt @($Rest).Count; $i += 2) {
    if ($Rest[$i] -notmatch '^-(\w+)$' -or $i + 1 -ge $Rest.Count) { throw "expected '-Name value' pairs, got '$($Rest[$i])'" }
    $named[$Matches[1]] = $Rest[$i + 1]
}
if ($named.ContainsKey('Sentinels')) { $named['Sentinels'] = @($named['Sentinels'] -split ';') }

$fn = @{
    'init' = 'Initialize-PwRegistry'; 'import' = 'Import-PwLedger'; 'status' = 'Get-PwStatus'; 'claim' = 'Request-PwClaim'
    'transition' = 'Set-PwState'; 'hold' = 'Set-PwHold'; 'clear-hold' = 'Clear-PwHold'; 'add-dir' = 'New-PwResourceDir'
    'add-worktree' = 'Add-PwWorktree'; 'register-process' = 'Register-PwProcess'; 'register-vm' = 'Register-PwLabVm'
    'register-asset' = 'Register-PwAsset'; 'record-merge' = 'Register-PwMerge'; 'cleanup' = 'Invoke-PwCleanup'
    'verify-cleanup' = 'Invoke-PwVerifyCleanup'
}[$Verb]
$result = & $fn @named
$result | ConvertTo-Json -Depth 30
if ($result -and $result.PSObject.Properties['Status'] -and $result.Status -in @('REFUSED', 'HOLD', 'INCOMPLETE', 'NOT_MERGED')) { exit 2 }
