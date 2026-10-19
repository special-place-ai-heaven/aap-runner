# Parity worktree, lease and cleanup gate (docs/parity/WORKTREES.md).
# Windows PowerShell 5.1 and PowerShell 7. Every failure path is fail-closed:
# a refusal changes nothing, a HOLD preserves everything and keeps the barrier shut.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if (-not ('ParityWork.SafeTree' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'SafeTree.cs') }

$script:States = @('NOT_STARTED', 'CLAIMED', 'IN_PROGRESS', 'VERIFIED', 'REVIEWED', 'PR_OPEN',
    'READY_TO_MERGE', 'MERGED_CLEANUP_REQUIRED', 'CLEANUP_VERIFIED', 'COMPLETE', 'HOLD')
$script:CleanupSteps = @('proof', 'inventory', 'evidence', 'processes', 'lab', 'dirs', 'worktrees', 'branch', 'base-sync', 'root')
$script:OnceSteps = @('proof', 'evidence', 'processes', 'lab', 'branch', 'base-sync')
$script:NeverKill = @('wsl.exe', 'wslhost.exe', 'vmmem', 'vmmem.exe', 'vmmemWSL', 'vmmemWSL.exe', 'docker*', 'com.docker*',
    'aap-runner-tray.exe', 'aap-runner-supervisor*')
$script:DefaultRegistry = 'C:\AI_STUFF\PROGRAMMING\aap-runner-work\parity\registry'
$script:LockDepth = 0
$script:Fault = $null
$script:Lab = $null
$script:GitHub = {
    param([string]$Repo, [int]$Number)
    $ErrorActionPreference = 'Continue'   # 5.1: a stderr line under Stop throws even on exit 0
    $json = & gh pr view $Number --repo $Repo --json 'url,state,baseRefName,headRefOid,mergeCommit' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "gh pr view exited $LASTEXITCODE" }
    ($json | Out-String) | ConvertFrom-Json
}

# ---- small helpers -----------------------------------------------------------

function Get-PwNow { [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss.fff') + 'Z' }  # not ISO: pwsh 7 JSON would turn ISO into DateTime

function Read-PwJson([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Write-PwJson([string]$Path, $Object) {
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('n')
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}

function Get-PwHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() } finally { $fs.Dispose(); $sha.Dispose() }
}

function Invoke-PwFault([string]$Point) {
    if ($script:Fault -eq $Point) { $script:Fault = $null; throw "PW_FAULT injected at $Point" }
}

function Invoke-PwGit {
    # Plain $args: no git flag can bind to a PowerShell parameter.
    $repo = $args[0]; $gitArgs = @($args | Select-Object -Skip 1)
    $ErrorActionPreference = 'Continue'
    $out = & git -C $repo @gitArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out | ForEach-Object { "$_" }) }
}

function Get-PwHoldError($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e) { if ($e -is [ParityWork.HoldException]) { return $e }; $e = $e.InnerException }
    $null
}

function New-PwResult([string]$Status, [string]$Reason, $Data) {
    [pscustomobject]@{ Status = $Status; Reason = $Reason; Data = $Data }
}

function Test-PwUnder([string]$Path, [string]$Root) {
    $p = $Path.TrimEnd('\'); $r = $Root.TrimEnd('\')
    $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Literal path validation in front of every deletion and registration.
function Assert-PwPath {
    param([string]$Path, [string]$Boundary, [string[]]$Sentinels)
    $bad = { param($why) throw [ParityWork.HoldException]::new('PATH', $Path, $why, $false) }
    if ([string]::IsNullOrWhiteSpace($Path)) { & $bad 'empty path' }
    if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) { & $bad 'UNC or device path' }
    if ($Path -notmatch '^[A-Za-z]:\\') { & $bad 'not an absolute drive path' }
    if ($Path.Substring(2).Contains(':')) { & $bad 'alternate data stream' }
    if ($Path -match '[*?"<>|/]') { & $bad 'wildcard or invalid character' }
    if (@($Path.Split('\') | Where-Object { $_ -eq '..' -or $_ -eq '.' }).Count -gt 0) { & $bad 'parent traversal' }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.TrimEnd('\').Equals($Path.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { & $bad 'path is not canonical' }
    if ($full.TrimEnd('\').Length -le 2) { & $bad 'drive root' }
    if (-not (Test-PwUnder $full $Boundary)) { & $bad 'outside the registered boundary' }
    foreach ($s in @($Sentinels)) {
        if (-not $s) { continue }
        if ((Test-PwUnder $full $s) -or (Test-PwUnder $s $full)) { & $bad "protected sentinel $s" }
    }
}

# The qualified deletion routine: validation, then handle-relative no-follow delete with
# at most three retries over fifteen seconds for sharing violations.
function Remove-PwOwnedTree {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path, [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Boundary, [string[]]$Sentinels, [switch]$RequireEmpty,
        [int]$RetryDelayMs = 5000)
    Assert-PwPath -Path $Path -Boundary $Boundary -Sentinels $Sentinels
    for ($try = 0; ; $try++) {
        try { return [ParityWork.SafeTree]::DeleteTree($Path, $Identity, [bool]$RequireEmpty) }
        catch {
            $h = Get-PwHoldError $_
            if (-not $h) { throw }
            if (-not $h.Retryable -or $try -ge 3) { throw $h }
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }
}

# No-follow presence: a dangling junction or symlink counts as present. Errors other
# than not-found (e.g. access denied) also count as present, so absence is only ever observed.
function Test-PwExists([string]$Path) {
    try { [void][IO.File]::GetAttributes($Path); $true }
    catch {
        $e = $_.Exception; if ($e.InnerException) { $e = $e.InnerException }
        -not ($e -is [IO.FileNotFoundException] -or $e -is [IO.DirectoryNotFoundException])
    }
}

function Get-PwIdentity([string]$Path) { [ParityWork.SafeTree]::GetIdentity($Path) }

function Set-PwProviders {
    param([scriptblock]$GitHub, [hashtable]$Lab)
    if ($GitHub) { $script:GitHub = $GitHub }
    if ($PSBoundParameters.ContainsKey('Lab')) { $script:Lab = $Lab }
}

function Set-PwFault([string]$Point) { $script:Fault = $Point }

# ---- registry, lock, state -----------------------------------------------------

function Invoke-PwLocked {
    param([string]$Registry, [scriptblock]$Body, [int]$TimeoutSec = 120)
    if ($script:LockDepth -gt 0) { return & $Body }
    $lockPath = Join-Path $Registry 'ledger.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ($true) {
        try { $fs = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None'); break }
        catch {
            if ([DateTime]::UtcNow -gt $deadline) { throw "ledger lock timeout: $lockPath" }
            Start-Sleep -Milliseconds 20
        }
    }
    $script:LockDepth++
    try { & $Body } finally { $script:LockDepth--; $fs.Dispose() }
}

function Get-PwConfig([string]$Registry) {
    $c = Read-PwJson (Join-Path $Registry 'config.json')
    if (-not $c) { throw "registry not initialized: $Registry" }
    $c
}
function Get-PwState([string]$Registry) { Read-PwJson (Join-Path $Registry 'state.json') }
function Save-PwState([string]$Registry, $State) { Write-PwJson (Join-Path $Registry 'state.json') $State }
function Get-PwManifestPath([string]$Registry, $It) { Join-Path $Registry ("manifests\{0}-attempt-{1}.json" -f $It.id, $It.attempt) }
function Get-PwEvidenceDir($Cfg, $It) { Join-Path $Cfg.evidence ("{0}\attempt-{1}" -f $It.id, $It.attempt) }

function Get-PwItem($State, [string]$Id) {
    $it = @($State.items | Where-Object { $_.id -eq $Id })
    if ($it.Count -ne 1) { throw "unknown item $Id" }
    $it[0]
}

function Test-PwBarrierClosed($State) {
    @($State.items | Where-Object {
            $_.state -eq 'MERGED_CLEANUP_REQUIRED' -or ($_.state -eq 'HOLD' -and $_.hold.after_merge)
        }).Count -gt 0
}

function Add-PwHistory($It, [string]$From, [string]$To, [string]$Actor, [string]$Note) {
    $It.history = @($It.history) + @([pscustomobject]@{ from = $From; to = $To; actor = $Actor; at = (Get-PwNow); note = $Note })
}

function Set-PwHoldOn($It, [string]$Reason, [string]$Owner, [bool]$AfterMerge, [string]$Actor, [bool]$Transient = $false) {
    $from = if ($It.state -eq 'HOLD') { $It.hold.from } else { $It.state }
    $It.hold = [pscustomobject]@{ reason = $Reason; owner = $Owner; from = $from; after_merge = $AfterMerge; at = (Get-PwNow); transient = $Transient }
    Add-PwHistory $It $It.state 'HOLD' $Actor $Reason
    $It.state = 'HOLD'
}

function Test-PwOverlap([string]$A, [string]$B) {
    # Conservative: two globs overlap when one's literal prefix contains the other's.
    $pa = ($A -split '[*?\[]')[0].TrimEnd('/'); $pb = ($B -split '[*?\[]')[0].TrimEnd('/')
    $pa = $pa.ToLowerInvariant(); $pb = $pb.ToLowerInvariant()
    ($pa -eq $pb) -or $pa.StartsWith($pb + '/') -or $pb.StartsWith($pa + '/') -or $pa -eq '' -or $pb -eq ''
}

function New-PwItemRecord($T) {
    $get = { param($n) if ($T.PSObject.Properties[$n]) { $T.$n } else { $null } }
    [pscustomobject]@{
        id = $T.id; needs = @(& $get 'needs' | Where-Object { $_ }); owns = @(& $get 'owns' | Where-Object { $_ })
        parent = (& $get 'parent'); children = @(& $get 'children' | Where-Object { $_ }); remainder_of = (& $get 'remainder_of')
        state = 'NOT_STARTED'; attempt = 0; owner = $null; leases = @(); verified_head = $null; verified_by = $null
        reviewed_head = $null; reviewed_by = $null; pr = $null; hold = $null; merge_proof = $null
        early_merge = $false; receipt = $null; history = @()
    }
}

# Adds new ledger tasks and applies revisions to NOT_STARTED items. Any revision of
# needs/owns/children/parent on an item that has left NOT_STARTED is refused.
function Import-PwLedger {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$LedgerPath)
    Invoke-PwLocked $Registry {
        $st = Get-PwState $Registry
        if (-not $st) { $st = [pscustomobject]@{ schema = 1; items = @() } }
        $tasks = @((Read-PwJson $LedgerPath).tasks)
        $shape = { param($r) (@($r.needs) -join ',') + '|' + (@($r.owns) -join ',') + '|' + (@($r.children) -join ',') + '|' + "$($r.parent)" }
        $new = @(); $revised = @()
        foreach ($t in $tasks) {
            $rec = New-PwItemRecord $t
            foreach ($id in @(@($rec.id) + @($rec.needs) + @($rec.children) + @($rec.parent, $rec.remainder_of) | Where-Object { $null -ne $_ })) {
                if ("$id" -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "bad item id '$id' in ledger" }
            }
            if ($rec.parent -and @($rec.needs) -contains $rec.parent) { throw "child $($rec.id) must not depend on its parent $($rec.parent)" }
            $old = @($st.items | Where-Object { $_.id -eq $rec.id })
            if ($old.Count -eq 0) { $new += $rec; continue }
            if ((& $shape $old[0]) -eq (& $shape $rec)) { continue }
            if ($old[0].state -ne 'NOT_STARTED') { throw "ledger revises $($rec.id) while it is $($old[0].state)" }
            $revised += , @($old[0], $rec)
        }
        foreach ($pair in $revised) { foreach ($f in @('needs', 'owns', 'children', 'parent')) { $pair[0].$f = $pair[1].$f } }
        $st.items = @($st.items) + $new
        Save-PwState $Registry $st
    }
}

function Initialize-PwRegistry {
    param([Parameter(Mandatory)][string]$Registry, [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][string]$WorkRoot, [Parameter(Mandatory)][string]$BaseClone,
        [Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$LedgerPath, [string[]]$Sentinels,
        [string[]]$DefaultSentinels = (Get-PwDefaultSentinels), [string]$Catalog)
    foreach ($p in @($WorkRoot, $Registry, $Evidence, $Catalog | Where-Object { $_ })) { Assert-PwPath -Path $p -Boundary $p }
    if ((Test-PwUnder $Registry $WorkRoot) -or (Test-PwUnder $Evidence $WorkRoot) -or ($Catalog -and (Test-PwUnder $Catalog $WorkRoot))) {
        throw 'registry, evidence and catalog must live outside the disposable work root'
    }
    if (-not [IO.Directory]::Exists($Registry)) { [void][IO.Directory]::CreateDirectory($Registry) }
    $cfg = [pscustomobject]@{
        schema = 1; evidence = $Evidence; work_root = $WorkRoot; base_clone = $BaseClone; repo = $Repo; catalog = $Catalog
        scratch = (Join-Path $Registry 'scratch')
        sentinels = @(@($BaseClone, $Registry, $Evidence) + @($DefaultSentinels) + @($Sentinels) | Where-Object { $_ })
    }
    Invoke-PwLocked $Registry { Write-PwJson (Join-Path $Registry 'config.json') $cfg }
    Import-PwLedger -Registry $Registry -LedgerPath $LedgerPath
}

function Get-PwDefaultSentinels {
    @('C:\Program Files\aap-runner', 'C:\wsl\aap-runner-supervisor', 'C:\temp\aap-cache-benchmark-2026-10-18',
        'C:\claude-obsidian\primus-cloud', 'C:\ProgramData\Docker', 'C:\ProgramData\DockerDesktop',
        (Join-Path $env:USERPROFILE '.cargo'), (Join-Path $env:USERPROFILE '.rustup'),
        (Join-Path $env:USERPROFILE 'claude-obsidian'), (Join-Path $env:LOCALAPPDATA 'Docker'))
}

function Get-PwStatus {
    param([string]$Registry = $script:DefaultRegistry)
    Invoke-PwLocked $Registry {
        $st = Get-PwState $Registry
        [pscustomobject]@{ BarrierClosed = (Test-PwBarrierClosed $st); Items = @($st.items) }
    }
}

function Get-PwDirtyInventory([string]$Repo) {
    $r = Invoke-PwGit $Repo status --porcelain=v1 --ignored=matching --untracked-files=all
    if ($r.Code -ne 0) { throw "git status failed in $Repo" }
    @($r.Out | Where-Object { $_ } | ForEach-Object {
            $rel = $_.Substring(3).Trim('"')
            $full = Join-Path $Repo $rel
            $hash = if ([IO.File]::Exists($full)) { Get-PwHash $full } elseif ([IO.Directory]::Exists($full)) { 'dir' } else { 'absent' }
            [pscustomobject]@{ entry = $_; hash = $hash }
        })
}

# ---- claim ----------------------------------------------------------------------

function Request-PwClaim {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Owner)
    Invoke-PwLocked $Registry {
        $cfg = Get-PwConfig $Registry
        $st = Get-PwState $Registry
        $it = Get-PwItem $st $Item
        if ($it.state -eq 'CLAIMED' -and $it.owner -eq $Owner) {
            $m = Read-PwJson (Get-PwManifestPath $Registry $it)
            if ($m -and -not $m.created) { return New-PwClaimResources $Registry $cfg $st $it $m }
        }
        if ($it.state -ne 'NOT_STARTED') { return New-PwResult 'REFUSED' "item is $($it.state)" $null }
        if (Test-PwBarrierClosed $st) { return New-PwResult 'REFUSED' 'global cleanup barrier is closed' $null }
        foreach ($n in @($it.needs)) {
            if ($it.parent -and $n -eq $it.parent) { return New-PwResult 'REFUSED' "child depends on its parent $n" $null }
            if ((Get-PwItem $st $n).state -ne 'COMPLETE') { return New-PwResult 'REFUSED' "dependency $n is not COMPLETE" $null }
        }
        foreach ($o in @($st.items | Where-Object { $_.id -ne $it.id -and @($_.leases).Count -gt 0 })) {
            foreach ($a in @($it.owns)) { foreach ($b in @($o.leases)) {
                    if (Test-PwOverlap $a $b) { return New-PwResult 'REFUSED' "ownership $a overlaps active lease $b of $($o.id)" $null }
                } }
        }
        $why = Test-PwUnobservedMerges $Registry $cfg $st $Owner
        if ($why) { return New-PwResult 'REFUSED' $why $null }
        $attempt = [int]$it.attempt + 1
        $root = Join-Path $cfg.work_root ("{0}\attempt-{1}" -f $it.id, $attempt)
        Assert-PwPath -Path $root -Boundary $cfg.work_root -Sentinels $cfg.sentinels
        $container = Split-Path $root -Parent
        Assert-PwPath -Path $container -Boundary $cfg.work_root -Sentinels $cfg.sentinels
        if ([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)) {
            Set-PwHoldOn $it "unregistered existing resource at $root" 'coordinator' $false $Owner
            Save-PwState $Registry $st
            return New-PwResult 'HOLD' "unregistered existing resource at $root" $null
        }
        if ((Invoke-PwGit $cfg.base_clone fetch --quiet origin).Code -ne 0) { return New-PwResult 'REFUSED' 'fetch of origin failed' $null }
        $base = (Invoke-PwGit $cfg.base_clone rev-parse 'refs/remotes/origin/main').Out[0]
        $dirs = @('tmp', 'target', 'logs') | ForEach-Object { [pscustomobject]@{ name = $_; path = (Join-Path $root $_); identity = $null } }
        $m = [pscustomobject]@{
            schema = 1; item = $it.id; attempt = $attempt; owner = $Owner; root = $root; root_identity = $null
            container = [pscustomobject]@{ path = $container; preexisting = [IO.Directory]::Exists($container); identity = $null }
            branch = ('parity/{0}-attempt-{1}' -f $it.id.ToLowerInvariant(), $attempt); base_sha = $base
            base_clone = $cfg.base_clone; base_inventory_initial = @(Get-PwDirtyInventory $cfg.base_clone)
            sentinels_initial = @($cfg.sentinels | ForEach-Object { [pscustomobject]@{ path = $_; exists = (Test-PwExists $_) } })
            worktrees = @([pscustomobject]@{ name = 'repo'; path = (Join-Path $root 'repo'); identity = $null; metadata = $null; head = $base })
            dirs = @($dirs)
            env = [pscustomobject]@{ TEMP = (Join-Path $root 'tmp'); TMP = (Join-Path $root 'tmp'); CARGO_TARGET_DIR = (Join-Path $root 'target') }
            processes = @(); lab = @(); assets = @(); leases = @($it.owns); evidence = @()
            verifier_scratch = $null; created = $false
            cleanup = [pscustomobject]@{ done = @(); observations = @(); base_after = $null; disposed = @() }
        }
        Write-PwJson (Get-PwManifestPath $Registry ([pscustomobject]@{ id = $it.id; attempt = $attempt })) $m
        $it.attempt = $attempt; $it.owner = $Owner; $it.leases = @($it.owns)
        Add-PwHistory $it 'NOT_STARTED' 'CLAIMED' $Owner "base $base"
        $it.state = 'CLAIMED'
        Save-PwState $Registry $st
        Invoke-PwFault 'claim:registered'
        New-PwClaimResources $Registry $cfg $st $it $m
    }
}

# Idempotent creation of already-registered claim resources.
function New-PwClaimResources($Registry, $Cfg, $St, $It, $M) {
    $mp = Get-PwManifestPath $Registry $It
    $c = $M.container
    if (-not [IO.Directory]::Exists($c.path)) { [void][IO.Directory]::CreateDirectory($c.path) }
    if (-not $c.preexisting -and -not $c.identity) { $c.identity = Get-PwIdentity $c.path; Write-PwJson $mp $M }
    if (-not [IO.Directory]::Exists($M.root)) { [void][IO.Directory]::CreateDirectory($M.root) }
    if (-not $M.root_identity) { $M.root_identity = Get-PwIdentity $M.root; Write-PwJson $mp $M }
    Invoke-PwFault 'claim:root-created'
    foreach ($d in @($M.dirs)) {
        if (-not [IO.Directory]::Exists($d.path)) { [void][IO.Directory]::CreateDirectory($d.path) }
        if (-not $d.identity) { $d.identity = Get-PwIdentity $d.path; Write-PwJson $mp $M }
    }
    $wt = @($M.worktrees)[0]
    $listed = (Invoke-PwGit $Cfg.base_clone worktree list --porcelain).Out -contains ('worktree ' + $wt.path.Replace('\', '/'))
    if (-not $listed) {
        $hasBranch = (Invoke-PwGit $Cfg.base_clone show-ref --verify --quiet "refs/heads/$($M.branch)").Code -eq 0
        $r = if ($hasBranch) { Invoke-PwGit $Cfg.base_clone worktree add $wt.path $M.branch } else { Invoke-PwGit $Cfg.base_clone worktree add -b $M.branch $wt.path $M.base_sha }
        if ($r.Code -ne 0) { throw "git worktree add failed: $($r.Out -join ' ')" }
    }
    if ((Invoke-PwGit $wt.path rev-parse HEAD).Out[0] -ne $M.base_sha -and -not $listed) { throw 'worktree is not at the recorded base' }
    $wt.identity = Get-PwIdentity $wt.path
    $wt.metadata = ([IO.File]::ReadAllText((Join-Path $wt.path '.git')) -replace '^gitdir:\s*', '').Trim().Replace('/', '\')
    $M.created = $true
    Write-PwJson $mp $M
    New-PwResult 'CLAIMED' '' $M
}

# ---- resource registration (always before creation) ------------------------------

function Update-PwManifest {
    param([string]$Registry, [string]$Item, [scriptblock]$Change)
    Invoke-PwLocked $Registry {
        $cfg = Get-PwConfig $Registry
        $it = Get-PwItem (Get-PwState $Registry) $Item
        $mp = Get-PwManifestPath $Registry $it
        $m = Read-PwJson $mp
        if (-not $m) { throw "no manifest for $Item" }
        $r = & $Change $m $cfg
        Write-PwJson $mp $m
        $r
    }
}

function New-PwResourceDir {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9._-]+$' -or $Name -match '^\.+$') { throw "bad resource name $Name" }
    $mp = $null
    Update-PwManifest $Registry $Item {
        param($m, $cfg)
        $path = Join-Path $m.root $Name
        Assert-PwPath -Path $path -Boundary $m.root -Sentinels $cfg.sentinels
        if (@($m.dirs | Where-Object { $_.name -eq $Name }).Count -eq 0 -and @($m.worktrees | Where-Object { $_.name -eq $Name }).Count -eq 0) {
            if (Test-PwExists $path) { throw "unregistered existing resource $path" }
            $m.dirs = @($m.dirs) + @([pscustomobject]@{ name = $Name; path = $path; identity = $null })
        }
    } | Out-Null
    Update-PwManifest $Registry $Item {
        param($m, $cfg)
        $d = @($m.dirs | Where-Object { $_.name -eq $Name })[0]
        if (-not [IO.Directory]::Exists($d.path)) { [void][IO.Directory]::CreateDirectory($d.path) }
        if (-not $d.identity) { $d.identity = Get-PwIdentity $d.path }
        $d.path
    }
}

# Registers an independent verification worktree (detached at the given commit).
function Add-PwWorktree {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [string]$Name = 'verify', [Parameter(Mandatory)][string]$Commit)
    Update-PwManifest $Registry $Item {
        param($m, $cfg)
        $path = Join-Path $m.root $Name
        Assert-PwPath -Path $path -Boundary $m.root -Sentinels $cfg.sentinels
        if (@($m.worktrees | Where-Object { $_.name -eq $Name }).Count -eq 0) {
            if (Test-PwExists $path) { throw "unregistered existing resource $path" }
            $m.worktrees = @($m.worktrees) + @([pscustomobject]@{ name = $Name; path = $path; identity = $null; metadata = $null; head = $Commit })
        }
    } | Out-Null
    Update-PwManifest $Registry $Item {
        param($m, $cfg)
        $wt = @($m.worktrees | Where-Object { $_.name -eq $Name })[0]
        if (-not [IO.Directory]::Exists($wt.path)) {
            $r = Invoke-PwGit $cfg.base_clone worktree add --detach $wt.path $Commit
            if ($r.Code -ne 0) { throw "git worktree add failed: $($r.Out -join ' ')" }
        }
        $wt.identity = Get-PwIdentity $wt.path
        $wt.metadata = ([IO.File]::ReadAllText((Join-Path $wt.path '.git')) -replace '^gitdir:\s*', '').Trim().Replace('/', '\')
        $wt.path
    }
}

function Register-PwProcess {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][int]$ProcessId)
    $h = [ParityWork.OwnedProcess]::Open($ProcessId, $false)
    if (-not $h) { throw "no process $ProcessId" }
    try { $ticks = $h.StartTicks; $image = $h.ImagePath } finally { $h.Dispose() }
    if (-not $image) { throw "process $ProcessId has exited" }
    Update-PwManifest $Registry $Item {
        param($m, $cfg)
        $m.processes = @($m.processes) + @([pscustomobject]@{ pid = $ProcessId; start_ticks = $ticks; image = $image })
    } | Out-Null
}

function Register-PwLabVm {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$VmId)
    Update-PwManifest $Registry $Item { param($m, $cfg) $m.lab = @($m.lab) + @([pscustomobject]@{ vm_id = $VmId }) } | Out-Null
}

function Register-PwAsset {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$AssetOwner,
        [Parameter(Mandatory)][string]$Retention, [Parameter(Mandatory)][string]$Expiry)
    Update-PwManifest $Registry $Item {
        param($m, $cfg)
        Assert-PwPath -Path $Source -Boundary $m.root
        if (-not $cfg.catalog) { throw 'no asset catalog root is configured' }
        Assert-PwPath -Path $Destination -Boundary $cfg.catalog -Sentinels $cfg.sentinels
        $m.assets = @($m.assets) + @([pscustomobject]@{ source = $Source; destination = $Destination; owner = $AssetOwner
                retention = $Retention; expiry = $Expiry; size = $null; sha256 = $null })
    } | Out-Null
}

# ---- transitions ----------------------------------------------------------------

function Test-PwMergeReady($State, $It) {
    foreach ($c in @($It.children)) {
        if ((Get-PwItem $State $c).state -notin @('CLEANUP_VERIFIED', 'COMPLETE')) { return $false }
    }
    $true
}

# Generic evidence-backed transitions. CLAIMED, MERGED_CLEANUP_REQUIRED, CLEANUP_VERIFIED
# and COMPLETE are reachable only through their dedicated, gated functions.
function Set-PwState {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)][string]$Actor, [string]$Head, [int]$Pr, [string]$Evidence)
    Invoke-PwLocked $Registry {
        $st = Get-PwState $Registry
        $it = Get-PwItem $st $Item
        $from = $it.state
        $ok = switch ("$from>$To") {
            'CLAIMED>IN_PROGRESS' { $it.owner -eq $Actor }
            'IN_PROGRESS>VERIFIED' { [bool]$Head -and $Actor -ne $it.owner }
            'VERIFIED>REVIEWED' { $Head -eq $it.verified_head -and $Actor -ne $it.owner }
            'REVIEWED>PR_OPEN' { $Pr -gt 0 -and $Head -eq $it.reviewed_head }
            'PR_OPEN>READY_TO_MERGE' { $Head -eq $it.reviewed_head -and (Test-PwMergeReady $st $it) -and -not (Test-PwBarrierClosed $st) }
            default { $false }
        }
        if ($To -eq 'IN_PROGRESS' -and $from -in @('VERIFIED', 'REVIEWED', 'PR_OPEN', 'READY_TO_MERGE')) {
            $ok = $true   # reviewed head changed: invalidate checks and reviews
            $it.verified_head = $null; $it.verified_by = $null; $it.reviewed_head = $null; $it.reviewed_by = $null
        }
        if (-not $ok) { return New-PwResult 'REFUSED' "illegal or unproven transition $from -> $To" $null }
        if ($To -eq 'READY_TO_MERGE') {
            $why = Test-PwUnobservedMerges $Registry (Get-PwConfig $Registry) $st $Actor
            if ($why) { return New-PwResult 'REFUSED' $why $null }
        }
        if ($To -eq 'VERIFIED') { $it.verified_head = $Head; $it.verified_by = $Actor }
        if ($To -eq 'REVIEWED') { $it.reviewed_head = $Head; $it.reviewed_by = $Actor }
        if ($To -eq 'PR_OPEN') { $it.pr = $Pr }
        Add-PwHistory $it $from $To $Actor $Evidence
        $it.state = $To
        Save-PwState $Registry $st
        New-PwResult 'OK' '' $null
    }
}

function Set-PwHold {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Reason, [Parameter(Mandatory)][string]$RecoveryOwner, [Parameter(Mandatory)][string]$Actor)
    Invoke-PwLocked $Registry {
        $st = Get-PwState $Registry
        $it = Get-PwItem $st $Item
        $after = $it.state -in @('MERGED_CLEANUP_REQUIRED', 'CLEANUP_VERIFIED') -or ($it.state -eq 'HOLD' -and $it.hold.after_merge)
        Set-PwHoldOn $it $Reason $RecoveryOwner $after $Actor
        Save-PwState $Registry $st
    }
}

# Only the recovery owner may release a pre-merge HOLD; post-merge holds resolve only by
# re-running the merge proof or cleanup.
function Clear-PwHold {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Actor)
    Invoke-PwLocked $Registry {
        $st = Get-PwState $Registry
        $it = Get-PwItem $st $Item
        if ($it.state -ne 'HOLD') { return New-PwResult 'REFUSED' 'not on HOLD' $null }
        if ($it.hold.after_merge) { return New-PwResult 'REFUSED' 'post-merge HOLD resolves via merge proof or cleanup' $null }
        if ($Actor -ne $it.hold.owner) { return New-PwResult 'REFUSED' "only $($it.hold.owner) may clear this HOLD" $null }
        Add-PwHistory $it 'HOLD' $it.hold.from $Actor 'hold cleared'
        $it.state = $it.hold.from; $it.hold = $null
        Save-PwState $Registry $st
        New-PwResult 'OK' '' $null
    }
}

# ---- merge proof ----------------------------------------------------------------

function Test-PwMergeProof($Cfg, $It) {
    $hold = { param($why) New-PwResult 'HOLD' $why $null }
    $transient = { param($why) New-PwResult 'HOLD' $why ([pscustomobject]@{ transient = $true }) }   # API/fetch: may recover
    if (-not $It.pr) { return New-PwResult 'NOT_MERGED' 'no pull request recorded (commit alone is not a merge)' $null }
    $accepted = $It.reviewed_head
    if (-not $accepted) { return & $hold 'no accepted reviewed head' }
    try { $pr = & $script:GitHub $Cfg.repo ([int]$It.pr) } catch { return & $transient "GitHub API failure: $($_.Exception.Message)" }
    if (-not $pr) { return & $transient 'GitHub API returned nothing' }
    if ($pr.state -ne 'MERGED') { return New-PwResult 'NOT_MERGED' "pull request is $($pr.state)" $null }
    if ($pr.url -ne ("https://github.com/{0}/pull/{1}" -f $Cfg.repo, $It.pr)) { return & $hold "wrong repository: $($pr.url)" }
    if ($pr.baseRefName -ne 'main') { return & $hold "wrong base $($pr.baseRefName)" }
    if ($pr.headRefOid -ne $accepted) { return & $hold "final head $($pr.headRefOid) is not the accepted head $accepted" }
    $merge = if ($pr.mergeCommit) { $pr.mergeCommit.oid } else { $null }
    if (-not $merge) { return & $hold 'no merge commit reported' }
    $g = $Cfg.base_clone
    if ((Invoke-PwGit $g fetch --quiet origin).Code -ne 0) { return & $transient 'fetch of origin failed' }
    $origin = (Invoke-PwGit $g rev-parse 'refs/remotes/origin/main').Out[0]
    if ((Invoke-PwGit $g merge-base --is-ancestor $merge $origin).Code -ne 0) { return & $hold "merge commit $merge is not reachable from origin/main" }
    if ((Invoke-PwGit $g cat-file -e "$accepted^{commit}").Code -ne 0) { return & $hold 'accepted head object missing' }
    # Candidate pre-merge mains: first parent (merge commit, squash) and the commit n
    # first-parent steps back (rebase, one landed commit per reviewed commit).
    $fork1 = (Invoke-PwGit $g merge-base $accepted "$merge^1").Out[0]
    if (-not $fork1) { return & $hold 'no common ancestor' }
    $n = [int](Invoke-PwGit $g rev-list --count "$fork1..$accepted").Out[0]
    if ($n -lt 1) { return & $hold 'reviewed head adds no commits over its merge base' }
    $pres = @("$merge^1", "$merge~$n") | ForEach-Object { $r = Invoke-PwGit $g rev-parse --verify --quiet "$_^{commit}"; if ($r.Code -eq 0) { $r.Out[0] } } | Select-Object -Unique
    # The landed change from pre to merge must equal the reviewed delta (fork..accepted)
    # applied onto pre: this accepts merge, squash and rebase merges with intervening
    # commits, without relying on original-head ancestry or patch IDs.
    foreach ($pre in $pres) {
        $fork = (Invoke-PwGit $g merge-base $accepted $pre).Out[0]
        if (-not $fork -or $fork -eq $accepted) { continue }
        $t = Invoke-PwGit $g merge-tree --write-tree --no-messages "--merge-base=$fork" $pre $accepted
        if ($t.Code -ne 0) { continue }
        if ((Invoke-PwGit $g diff --quiet --no-renames $t.Out[0] $merge).Code -eq 0) {
            return New-PwResult 'OK' '' ([pscustomobject]@{
                    pr_url = $pr.url; accepted_head = $accepted; merge_sha = $merge; origin_main_sha = $origin
                    fork = $fork; pre_merge = $pre; comparison = 'MATCH: landed tree equals reviewed delta applied to pre-merge main'
                    observed = (Get-PwNow)
                })
        }
    }
    & $hold 'merged result differs from the reviewed result'
}

# Observes a merge. Records it (closing the barrier) when proven; HOLDs on any doubt.
function Register-PwMerge {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Actor)
    Invoke-PwLocked $Registry {
        $cfg = Get-PwConfig $Registry
        $st = Get-PwState $Registry
        $it = Get-PwItem $st $Item
        $phase = if ($it.state -eq 'HOLD') { $it.hold.from } else { $it.state }
        if ($phase -notin @('PR_OPEN', 'READY_TO_MERGE')) { return New-PwResult 'REFUSED' "item is $($it.state)" $null }
        $proof = Test-PwMergeProof $cfg $it
        if ($proof.Status -eq 'NOT_MERGED') {
            # A post-merge HOLD that only came from an API/fetch failure reverts to a
            # pre-merge HOLD the coordinator can clear: the barrier reopens.
            if ($it.state -eq 'HOLD' -and $it.hold.after_merge -and $it.hold.PSObject.Properties['transient'] -and $it.hold.transient) {
                $it.hold.after_merge = $false; $it.hold.transient = $false
                Add-PwHistory $it 'HOLD' 'HOLD' $Actor "merge not observed after transient proof failure: $($proof.Reason)"
                Save-PwState $Registry $st
            }
            return $proof
        }
        Save-PwMergeObservation $Registry $cfg $st $it $proof $Actor
        $proof
    }
}

# Records a merge proof result: a proven merge closes the barrier; doubt is a post-merge HOLD.
function Save-PwMergeObservation($Registry, $Cfg, $St, $It, $Proof, [string]$Actor) {
    if ($Proof.Status -ne 'OK') {
        Set-PwHoldOn $It $Proof.Reason 'coordinator' $true $Actor ([bool]($Proof.Data -and $Proof.Data.transient))
        Save-PwState $Registry $St
        return
    }
    $It.merge_proof = $Proof.Data
    $It.early_merge = -not (Test-PwMergeReady $St $It)
    Write-PwJson (Join-Path (Get-PwEvidenceDir $Cfg $It) 'merge-proof.json') $Proof.Data
    Add-PwHistory $It $It.state 'MERGED_CLEANUP_REQUIRED' $Actor $Proof.Data.merge_sha
    $It.state = 'MERGED_CLEANUP_REQUIRED'; $It.hold = $null
    Save-PwState $Registry $St
}

# Under the lock: proves every open PR before a grant. An external merge nobody observed
# is recorded (closing the barrier); any merge or uncertainty returns a refusal reason.
function Test-PwUnobservedMerges($Registry, $Cfg, $St, [string]$Actor) {
    foreach ($o in @($St.items)) {
        $phase = if ($o.state -eq 'HOLD' -and -not $o.hold.after_merge) { $o.hold.from } else { $o.state }
        if ($phase -notin @('PR_OPEN', 'READY_TO_MERGE') -or -not $o.pr) { continue }
        $p = Test-PwMergeProof $Cfg $o
        if ($p.Status -eq 'NOT_MERGED') { continue }
        if ($p.Status -eq 'HOLD' -and $p.Data -and $p.Data.transient) { return "merge state of $($o.id) is uncertain: $($p.Reason)" }
        Save-PwMergeObservation $Registry $Cfg $St $o $p $Actor
        return "observed an unrecorded merge of $($o.id)"
    }
    $null
}

# ---- cleanup --------------------------------------------------------------------

function Get-PwOwnedProcessScan($M) {
    $ownedPids = @($M.processes | ForEach-Object { [int]$_.pid })
    @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and (Test-PwUnder $_.ExecutablePath $M.root) -and $ownedPids -notcontains [int]$_.ProcessId
        } | ForEach-Object { "pid $($_.ProcessId) $($_.Name)" })
}

function Assert-PwWorktreeClean($Wt) {
    if (-not [IO.Directory]::Exists($Wt.path)) { return }
    $inv = @(Get-PwDirtyInventory $Wt.path)
    if ($inv.Count -gt 0) {
        throw [ParityWork.HoldException]::new('DIRTY', $Wt.name, "unowned tracked/untracked/ignored entries preserved: $(@($inv | ForEach-Object entry) -join '; ')", $false)
    }
}

function Invoke-PwCleanupStep([string]$Step, $Cfg, $It, $M, [int]$RetryDelayMs) {
    $hold = { param($code, $why) throw [ParityWork.HoldException]::new($code, $Step, $why, $false) }
    $obs = { param($o) $M.cleanup.observations = @($M.cleanup.observations) + @($o) }
    switch ($Step) {
        'proof' {
            $p = Test-PwMergeProof $Cfg $It
            if ($p.Status -ne 'OK') { & $hold 'MERGE_PROOF' $p.Reason }
            if ($p.Data.merge_sha -ne $It.merge_proof.merge_sha) { & $hold 'MERGE_PROOF' 'merge identity changed since it was recorded' }
        }
        'inventory' {
            if ([IO.Directory]::Exists($M.root)) {
                $known = @(@($M.dirs) + @($M.worktrees) | ForEach-Object name)
                $extra = @(Get-ChildItem -LiteralPath $M.root -Force | Where-Object { $known -notcontains $_.Name } | ForEach-Object Name)
                if ($extra.Count -gt 0) { & $hold 'UNREGISTERED' "unregistered entries preserved in attempt root: $($extra -join ', ')" }
            }
            foreach ($wt in @($M.worktrees)) { Assert-PwWorktreeClean $wt }
            $unknown = @(Get-PwOwnedProcessScan $M)
            if ($unknown.Count -gt 0) { & $hold 'UNKNOWN_PROCESS' "unregistered process running from the attempt root: $($unknown -join ', ')" }
        }
        'evidence' {
            $dir = Get-PwEvidenceDir $Cfg $It
            Write-PwJson (Join-Path $dir 'evidence.json') ([pscustomobject]@{
                    item = $It.id; attempt = $It.attempt; verified_head = $It.verified_head; tested_by = $It.verified_by
                    reviewed_head = $It.reviewed_head; reviewed_by = $It.reviewed_by; merge_proof = $It.merge_proof; history = @($It.history)
                })
            foreach ($a in @($M.assets)) {
                Assert-PwPath -Path $a.destination -Boundary $Cfg.catalog -Sentinels $Cfg.sentinels
                # No-follow open: a reparse point anywhere on the source path, or a hard link, is HOLD.
                $src = [ParityWork.SafeTree]::OpenFileNoFollow($a.source)
                try {
                    if (-not [IO.File]::Exists($a.destination)) {
                        $dd = [IO.Path]::GetDirectoryName($a.destination)
                        if (-not [IO.Directory]::Exists($dd)) { [void][IO.Directory]::CreateDirectory($dd) }
                        $out = [IO.File]::Open($a.destination, 'CreateNew', 'Write', 'None')
                        try { $src.CopyTo($out) } finally { $out.Dispose() }
                        $src.Position = 0
                    }
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $srcHash = ([BitConverter]::ToString($sha.ComputeHash($src))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
                } finally { $src.Dispose() }
                $a.sha256 = Get-PwHash $a.destination
                $a.size = ([IO.FileInfo]$a.destination).Length
                if ($srcHash -ne $a.sha256) { & $hold 'ASSET' "asset destination differs from source: $($a.destination)" }
            }
        }
        'processes' {
            foreach ($p in @($M.processes)) {
                # One handle: identity is read from it and termination goes through it.
                $h = [ParityWork.OwnedProcess]::Open([int]$p.pid, $true)
                try {
                    if (-not $h -or $h.HasExited) { & $obs ([pscustomobject]@{ kind = 'process'; id = $p.pid; result = 'absent' }) }
                    elseif ($h.StartTicks -ne $p.start_ticks) { & $obs ([pscustomobject]@{ kind = 'process'; id = $p.pid; result = 'pid reused (start time differs); not killed' }) }
                    else {
                        foreach ($img in @($p.image, $h.ImagePath)) {
                            $leaf = Split-Path $img -Leaf
                            if (@($script:NeverKill | Where-Object { $leaf -like $_ }).Count -gt 0) { & $hold 'PROCESS' "image $img is on the never-kill denylist; not killed" }
                            if (@($Cfg.sentinels | Where-Object { $_ -and (Test-PwUnder $img $_) }).Count -gt 0) { & $hold 'PROCESS' "image $img is under a protected sentinel; not killed" }
                        }
                        if ($h.ImagePath -ne $p.image) { & $hold 'PROCESS' "process $($p.pid) image differs from registration; not killed" }
                        if (-not $h.Terminate(10000)) { & $hold 'PROCESS' "owned process $($p.pid) did not exit" }
                        & $obs ([pscustomobject]@{ kind = 'process'; id = $p.pid; result = 'stopped; absence observed' })
                    }
                } finally { if ($h) { $h.Dispose() } }
            }
        }
        'lab' {
            foreach ($vm in @($M.lab)) {
                if (-not $script:Lab) { & $hold 'LAB' "no lab provider for $($vm.vm_id)" }
                $gone = $false
                for ($i = 0; $i -lt 4 -and -not $gone; $i++) {
                    if ($i -gt 0) { Start-Sleep -Milliseconds $RetryDelayMs }
                    try { & $script:Lab.Destroy $vm.vm_id } catch { }
                    try { $gone = -not (& $script:Lab.Exists $vm.vm_id) } catch { $gone = $false }
                }
                if (-not $gone) { & $hold 'LAB' "guest teardown not observed for $($vm.vm_id)" }
                & $obs ([pscustomobject]@{ kind = 'lab'; id = $vm.vm_id; result = 'destroyed; absence observed' })
            }
        }
        'dirs' {
            foreach ($d in @($M.dirs)) {
                if (Test-PwExists $d.path) {
                    if (-not $d.identity) { & $hold 'IDENTITY' "registered $($d.name) exists without a recorded identity" }
                    [void](Remove-PwOwnedTree -Path $d.path -Identity $d.identity -Boundary $M.root -Sentinels $Cfg.sentinels -RetryDelayMs $RetryDelayMs)
                }
                $M.cleanup.disposed = @(@($M.cleanup.disposed | Where-Object { $_.id -ne "dir:$($d.name)" }) + @([pscustomobject]@{ id = "dir:$($d.name)"; path = $d.path }))
            }
        }
        'worktrees' {
            foreach ($wt in @($M.worktrees)) {
                if (Test-PwExists $wt.path) {
                    Assert-PwWorktreeClean $wt
                    if (-not $wt.identity) { & $hold 'IDENTITY' "registered worktree $($wt.name) exists without a recorded identity" }
                    [void](Remove-PwOwnedTree -Path $wt.path -Identity $wt.identity -Boundary $M.root -Sentinels $Cfg.sentinels -RetryDelayMs $RetryDelayMs)
                }
                $entry = 'worktree ' + $wt.path.Replace('\', '/')
                if ((Invoke-PwGit $Cfg.base_clone worktree list --porcelain).Out -contains $entry) {
                    $r = Invoke-PwGit $Cfg.base_clone worktree remove $wt.path
                    if ($r.Code -ne 0) { & $hold 'WORKTREE' "git worktree remove failed: $($r.Out -join ' ')" }
                }
                if ((Invoke-PwGit $Cfg.base_clone worktree list --porcelain).Out -contains $entry) { & $hold 'WORKTREE' "worktree entry still listed: $($wt.name)" }
                if ($wt.metadata -and (Test-PwExists $wt.metadata)) { & $hold 'WORKTREE' "worktree metadata still present: $($wt.metadata)" }
                $M.cleanup.disposed = @(@($M.cleanup.disposed | Where-Object { $_.id -ne "worktree:$($wt.name)" }) + @([pscustomobject]@{ id = "worktree:$($wt.name)"; path = $wt.path }))
            }
        }
        'branch' {
            $ref = "refs/heads/$($M.branch)"
            $how = 'already absent'
            if ((Invoke-PwGit $Cfg.base_clone show-ref --verify --quiet $ref).Code -eq 0) {
                $how = 'deleted with non-force branch -d'
                if ((Invoke-PwGit $Cfg.base_clone branch -d $M.branch).Code -ne 0) {
                    # Squash/rebase: compare-and-swap delete tied to the proven accepted head.
                    $r = Invoke-PwGit $Cfg.base_clone update-ref -d $ref $It.merge_proof.accepted_head
                    if ($r.Code -ne 0) { & $hold 'BRANCH' "branch moved from the accepted head; preserved" }
                    $how = "deleted by compare-and-swap at accepted head $($It.merge_proof.accepted_head)"
                }
            }
            if ((Invoke-PwGit $Cfg.base_clone show-ref --verify --quiet $ref).Code -eq 0) { & $hold 'BRANCH' 'branch still present' }
            & $obs ([pscustomobject]@{ kind = 'branch'; id = $M.branch; result = "$how (local only; remote untouched)" })
        }
        'base-sync' {
            $g = $Cfg.base_clone
            if ((Invoke-PwGit $g symbolic-ref --quiet HEAD).Out[0] -ne 'refs/heads/main') { & $hold 'BASE' 'base clone is not on main; not touched' }
            $before = @(Get-PwDirtyInventory $g)
            $pre = (Invoke-PwGit $g rev-parse HEAD).Out[0]
            if ((Invoke-PwGit $g fetch --quiet origin).Code -ne 0) { & $hold 'BASE' 'fetch failed' }
            $r = Invoke-PwGit $g merge --ff-only --no-overwrite-ignore --quiet 'refs/remotes/origin/main'
            if ($r.Code -ne 0) { & $hold 'BASE' "fast-forward refused; base preserved: $($r.Out -join ' ')" }
            $after = @(Get-PwDirtyInventory $g)
            foreach ($b in $before) {
                if (@($after | Where-Object { $_.entry -eq $b.entry -and $_.hash -eq $b.hash }).Count -eq 0) { & $hold 'BASE' "pre-existing change not preserved: $($b.entry)" }
            }
            $M.cleanup.base_after = [pscustomobject]@{ before_sha = $pre; after_sha = (Invoke-PwGit $g rev-parse HEAD).Out[0]
                origin_sha = (Invoke-PwGit $g rev-parse 'refs/remotes/origin/main').Out[0]; preserved = @($after) }
        }
        'root' {
            if (Test-PwExists $M.root) {
                [void](Remove-PwOwnedTree -Path $M.root -Identity $M.root_identity -Boundary $M.root -Sentinels $Cfg.sentinels -RequireEmpty -RetryDelayMs $RetryDelayMs)
            }
            $M.cleanup.disposed = @(@($M.cleanup.disposed | Where-Object { $_.id -ne 'root' }) + @([pscustomobject]@{ id = 'root'; path = $M.root }))
            $c = $M.container
            if (-not $c.preexisting) {
                # Created by this claim: removed only when empty; other attempts' entries HOLD.
                if (Test-PwExists $c.path) {
                    if (-not $c.identity) { & $hold 'IDENTITY' "item container $($c.path) exists without a recorded identity" }
                    [void](Remove-PwOwnedTree -Path $c.path -Identity $c.identity -Boundary $Cfg.work_root -Sentinels $Cfg.sentinels -RequireEmpty -RetryDelayMs $RetryDelayMs)
                }
                $M.cleanup.disposed = @(@($M.cleanup.disposed | Where-Object { $_.id -ne 'container' }) + @([pscustomobject]@{ id = 'container'; path = $c.path }))
            }
        }
    }
}

# Steps 1-7 of WORKTREES.md. Resumes from the last persisted step; any doubt is HOLD.
function Invoke-PwCleanup {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Actor, [int]$RetryDelayMs = 5000)
    Invoke-PwLocked $Registry {
        $cfg = Get-PwConfig $Registry
        $st = Get-PwState $Registry
        $it = Get-PwItem $st $Item
        $resumable = $it.state -eq 'HOLD' -and $it.hold.from -eq 'MERGED_CLEANUP_REQUIRED'
        if ($it.state -ne 'MERGED_CLEANUP_REQUIRED' -and -not $resumable) {
            return New-PwResult 'REFUSED' "cleanup requires a proven merge; item is $($it.state)" $null
        }
        if ($resumable) {
            Add-PwHistory $it 'HOLD' 'MERGED_CLEANUP_REQUIRED' $Actor 'cleanup resumed'
            $it.state = 'MERGED_CLEANUP_REQUIRED'; $it.hold = $null
            Save-PwState $Registry $st
        }
        $mp = Get-PwManifestPath $Registry $it
        $m = Read-PwJson $mp
        foreach ($step in $script:CleanupSteps) {
            if ($script:OnceSteps -contains $step -and @($m.cleanup.done) -contains $step) { continue }
            try { Invoke-PwCleanupStep $step $cfg $it $m $RetryDelayMs }
            catch {
                $h = Get-PwHoldError $_
                $why = if ($h) { $h.Message } else { "$step failed: $($_.Exception.Message)" }
                Write-PwJson $mp $m
                Set-PwHoldOn $it $why 'coordinator' $true $Actor
                Save-PwState $Registry $st
                return New-PwResult 'HOLD' $why $null
            }
            if (@($m.cleanup.done) -notcontains $step) { $m.cleanup.done = @($m.cleanup.done) + @($step) }
            Write-PwJson $mp $m
            Invoke-PwFault "cleanup:$step"
        }
        New-PwResult 'CLEANED' 'awaiting independent verification' $null
    }
}

# Step 8: independent verifier. Writes the receipt atomically, then releases leases and
# marks COMPLETE. Any residue leaves the item MERGED_CLEANUP_REQUIRED (barrier closed).
function Invoke-PwVerifyCleanup {
    param([string]$Registry = $script:DefaultRegistry, [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Verifier, [int]$RetryDelayMs = 5000)
    Invoke-PwLocked $Registry {
        $cfg = Get-PwConfig $Registry
        $st = Get-PwState $Registry
        $it = Get-PwItem $st $Item
        if (-not $Verifier -or $Verifier -eq $it.owner) { return New-PwResult 'REFUSED' 'verifier must be a different identity from the implementer' $null }
        $mp = Get-PwManifestPath $Registry $it
        $m = Read-PwJson $mp
        if ((Test-PwUnder (Get-Location).ProviderPath $m.root) -or (Test-PwUnder $PSScriptRoot $m.root)) {
            return New-PwResult 'REFUSED' 'verifier must run outside the attempt root' $null
        }
        if ($it.state -eq 'MERGED_CLEANUP_REQUIRED') {
            $missing = @($script:CleanupSteps | Where-Object { @($m.cleanup.done) -notcontains $_ })
            if ($missing.Count -gt 0) { return New-PwResult 'INCOMPLETE' "cleanup steps not done: $($missing -join ', ')" $null }
            if ($it.early_merge -and @($st.items | Where-Object { $_.remainder_of -eq $it.id }).Count -eq 0) {
                return New-PwResult 'INCOMPLETE' 'parent merged early: record a remainder item first' $null
            }
            $r = New-PwReceipt $Registry $cfg $it $m $mp $Verifier $RetryDelayMs
            if ($r.Status -ne 'OK') { return $r }
            $it.receipt = $r.Data
            Add-PwHistory $it 'MERGED_CLEANUP_REQUIRED' 'CLEANUP_VERIFIED' $Verifier $r.Data.path
            $it.state = 'CLEANUP_VERIFIED'
            Save-PwState $Registry $st
            Invoke-PwFault 'verify:receipt-persisted'
        }
        if ($it.state -ne 'CLEANUP_VERIFIED') { return New-PwResult 'REFUSED' "item is $($it.state)" $null }
        if ($it.early_merge) {
            # The merged attempt is clean and the barrier may reopen, but the parent stays
            # incomplete: its remainder item carries the rest. Never manufacture COMPLETE.
            if (@($it.leases).Count -gt 0) {
                Add-PwHistory $it 'CLEANUP_VERIFIED' 'CLEANUP_VERIFIED' $Verifier "early merge; released leases: $(@($it.leases) -join ', ')"
                $it.leases = @(); Save-PwState $Registry $st
            }
            return New-PwResult 'CLEANUP_VERIFIED' 'parent merged early: stays incomplete; remainder item recorded' $null
        }
        $rec = Read-PwJson $it.receipt.path
        if (-not $rec -or (Get-PwHash $it.receipt.path) -ne $it.receipt.sha256 -or $rec.verifier -eq $it.owner -or $rec.verifier -ne $Verifier) {
            return New-PwResult 'REFUSED' 'receipt missing, altered or not independent' $null
        }
        Add-PwHistory $it 'CLEANUP_VERIFIED' 'COMPLETE' $Verifier "released leases: $(@($it.leases) -join ', ')"
        $it.leases = @(); $it.state = 'COMPLETE'
        Save-PwState $Registry $st
        New-PwResult 'COMPLETE' '' $rec
    }
}

function New-PwReceipt($Registry, $Cfg, $It, $M, $Mp, $Verifier, $RetryDelayMs) {
    $fail = New-Object System.Collections.Generic.List[string]
    # Verifier scratch is registered before creation and removed before the receipt.
    $sp = Join-Path $Cfg.scratch ("{0}-attempt-{1}-verify" -f $It.id, $It.attempt)
    if (-not $M.verifier_scratch) { $M.verifier_scratch = [pscustomobject]@{ path = $sp; identity = $null }; Write-PwJson $Mp $M }
    if ([IO.Directory]::Exists($sp) -and -not $M.verifier_scratch.identity) { return New-PwResult 'INCOMPLETE' "verifier scratch exists without identity: $sp" $null }
    if (-not [IO.Directory]::Exists($sp)) { [void][IO.Directory]::CreateDirectory($sp); $M.verifier_scratch.identity = Get-PwIdentity $sp; Write-PwJson $Mp $M }
    Invoke-PwFault 'verify:scratch-created'
    $g = $Cfg.base_clone
    $wtList = (Invoke-PwGit $g worktree list --porcelain).Out
    [IO.File]::WriteAllLines((Join-Path $sp 'worktree-list.txt'), [string[]]$wtList)
    $absent = @()
    $owned = @(@($M.dirs) + @($M.worktrees) + @([pscustomobject]@{ name = 'root'; path = $M.root }))
    if (-not $M.container.preexisting) { $owned += [pscustomobject]@{ name = 'container'; path = $M.container.path } }
    foreach ($r in $owned) {
        if (Test-PwExists $r.path) { $fail.Add("still present: $($r.path)") } else { $absent += [pscustomobject]@{ id = $r.name; path = $r.path; observed_absent = $true } }
    }
    foreach ($wt in @($M.worktrees)) {
        if ($wtList -contains ('worktree ' + $wt.path.Replace('\', '/'))) { $fail.Add("worktree still listed: $($wt.name)") }
        if ($wt.metadata -and (Test-PwExists $wt.metadata)) { $fail.Add("worktree metadata present: $($wt.metadata)") }
    }
    if ((Invoke-PwGit $g show-ref --verify --quiet "refs/heads/$($M.branch)").Code -eq 0) { $fail.Add("branch present: $($M.branch)") }
    $procs = @()
    foreach ($p in @($M.processes)) {
        $alive = $true   # unreadable counts as alive: absence is only ever observed
        try {
            $h = [ParityWork.OwnedProcess]::Open([int]$p.pid, $false)
            if (-not $h) { $alive = $false } else { try { $alive = -not $h.HasExited -and $h.StartTicks -eq $p.start_ticks } finally { $h.Dispose() } }
        } catch { }
        if ($alive) { $fail.Add("owned process alive: $($p.pid)") }
        $procs += [pscustomobject]@{ pid = $p.pid; start_ticks = $p.start_ticks; owned_instance_running = [bool]$alive }
    }
    foreach ($vm in @($M.lab)) {
        $exists = $true
        try { $exists = [bool](& $script:Lab.Exists $vm.vm_id) } catch { }
        if ($exists) { $fail.Add("lab guest not observed absent: $($vm.vm_id)") } else { $absent += [pscustomobject]@{ id = "vm:$($vm.vm_id)"; path = $null; observed_absent = $true } }
    }
    foreach ($a in @($M.assets)) {
        if (-not [IO.File]::Exists($a.destination) -or (Get-PwHash $a.destination) -ne $a.sha256) { $fail.Add("retained asset missing or changed: $($a.destination)") }
    }
    $baseNow = @(Get-PwDirtyInventory $g)
    foreach ($b in @($M.cleanup.base_after.preserved)) {
        if (@($baseNow | Where-Object { $_.entry -eq $b.entry -and $_.hash -eq $b.hash }).Count -eq 0) { $fail.Add("base clone state changed: $($b.entry)") }
    }
    $sentinels = @($M.sentinels_initial | ForEach-Object { [pscustomobject]@{ path = $_.path; existed = $_.exists; exists = (Test-PwExists $_.path) } })
    foreach ($s in $sentinels) { if ($s.existed -and -not $s.exists) { $fail.Add("protected path missing: $($s.path)") } }
    try { [void](Remove-PwOwnedTree -Path $sp -Identity $M.verifier_scratch.identity -Boundary $Cfg.scratch -Sentinels @() -RetryDelayMs $RetryDelayMs) }
    catch { $fail.Add("verifier scratch not removed: $($_.Exception.Message)") }
    if (Test-PwExists $sp) { $fail.Add("verifier scratch still present: $sp") } else { $absent += [pscustomobject]@{ id = 'verifier-scratch'; path = $sp; observed_absent = $true } }
    if ($fail.Count -gt 0) { return New-PwResult 'INCOMPLETE' ($fail -join '; ') $null }

    $receipt = [pscustomobject]@{
        schema = 1; item = $It.id; attempt = $It.attempt; final_reviewed_head = $It.reviewed_head
        pr_url = $It.merge_proof.pr_url; merge_sha = $It.merge_proof.merge_sha; base_sha = $M.base_sha
        origin_main_sha = $M.cleanup.base_after.origin_sha; merge_comparison = $It.merge_proof.comparison
        implementer = $It.owner; tested_by = $It.verified_by; reviewed_by = $It.reviewed_by
        protected_state = [pscustomobject]@{ base_clone_initial = @($M.base_inventory_initial); base_clone_after = @($M.cleanup.base_after.preserved)
            base_before_sha = $M.cleanup.base_after.before_sha; base_after_sha = $M.cleanup.base_after.after_sha; sentinels = $sentinels }
        disposed = $absent; retained_assets = @($M.assets | ForEach-Object { [pscustomobject]@{ destination = $_.destination; owner = $_.owner; retention = $_.retention; expiry = $_.expiry; size = $_.size; sha256 = $_.sha256 } })
        process_observations = @($M.cleanup.observations) + @($procs); released_leases = @($It.leases)
        verifier = $Verifier; cleanup_started = @($It.history | Where-Object { $_.to -eq 'MERGED_CLEANUP_REQUIRED' } | Select-Object -Last 1 | ForEach-Object at)
        verified_at = (Get-PwNow)
    }
    $path = Join-Path (Get-PwEvidenceDir $Cfg $It) 'receipt.json'
    Write-PwJson $path $receipt
    New-PwResult 'OK' '' ([pscustomobject]@{ path = $path; sha256 = (Get-PwHash $path); verifier = $Verifier })
}

Export-ModuleMember -Function Initialize-PwRegistry, Import-PwLedger, Get-PwStatus, Request-PwClaim, Set-PwState,
    Set-PwHold, Clear-PwHold, New-PwResourceDir, Add-PwWorktree, Register-PwProcess, Register-PwLabVm, Register-PwAsset,
    Register-PwMerge, Invoke-PwCleanup, Invoke-PwVerifyCleanup, Remove-PwOwnedTree, Get-PwIdentity, Set-PwProviders,
    Set-PwFault
