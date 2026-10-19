# Shared fixtures for the parity-work Pester suites. Everything is created under
# $TestDrive: a bare "origin", a dirty base clone, a maintainer clone that performs
# merges, fixture sentinels and a file-backed fake GitHub. Nothing real is touched.

$script:PwModule = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\parity-work\ParityWork.psm1')).ProviderPath
$script:Junctions = New-Object System.Collections.Generic.List[string]

function Invoke-Fx {
    # Plain $args: no git flag can bind to a PowerShell parameter.
    $repo = $args[0]; $a = @($args | Select-Object -Skip 1)
    $ErrorActionPreference = 'Continue'
    $out = @(& git -C $repo @a 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "git $($a -join ' ') failed: $($out -join ' ')" }
    , $out
}

function Write-FxFile([string]$Path, [string]$Text) {
    $d = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

function Get-FxTreeHash([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return 'absent' }
    $lines = Get-ChildItem -LiteralPath $Dir -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Dir.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    ($lines -join "`n")
}

function New-FxJunction([string]$Path, [string]$Target) {
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    $script:Junctions.Add($Path)
}

# Removes fixture junctions without following them (before Pester deletes TestDrive).
function Remove-FxJunctions {
    foreach ($j in @($script:Junctions)) {
        if ([IO.Directory]::Exists($j) -and ((Get-Item -LiteralPath $j -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($j) }
    }
    $script:Junctions.Clear()
}

function New-FakeGitHub([string]$File) {
    [scriptblock]::Create(@"
param(`$Repo, `$Number)
`$all = [IO.File]::ReadAllText('$File') | ConvertFrom-Json
`$p = `$all.PSObject.Properties["`$Number"]
if (-not `$p) { throw "no such pull request `$Number" }
if (`$p.Value -is [string]) { throw 'GitHub API unavailable' }
`$p.Value
"@)
}

function Set-FxPr($Fx, [int]$Number, $Pr) {
    $all = [IO.File]::ReadAllText($Fx.Gh) | ConvertFrom-Json
    $all.PSObject.Properties.Remove("$Number")
    $all.PSObject.Properties.Add((New-Object Management.Automation.PSNoteProperty "$Number", $Pr))
    [IO.File]::WriteAllText($Fx.Gh, ($all | ConvertTo-Json -Depth 10))
}

function Set-FxMergedPr($Fx, $Ready, [string]$MergeSha, [string]$Head, [string]$Base = 'main', [string]$Repo = 'fx/repo', [string]$State = 'MERGED') {
    if (-not $Head) { $Head = $Ready.Head }
    $mc = if ($MergeSha) { [pscustomobject]@{ oid = $MergeSha } } else { $null }
    Set-FxPr $Fx $Ready.Pr ([pscustomobject]@{ url = "https://github.com/$Repo/pull/$($Ready.Pr)"; state = $State; baseRefName = $Base; headRefOid = $Head; mergeCommit = $mc })
}

function Get-FxDefaultTasks {
    @(
        [pscustomobject]@{ id = 'A'; needs = @(); owns = @('src/a/**') },
        [pscustomobject]@{ id = 'B'; needs = @(); owns = @('src/b/**') },
        [pscustomobject]@{ id = 'C'; needs = @('A'); owns = @('src/c/**') },
        [pscustomobject]@{ id = 'D'; needs = @(); owns = @('src/**') }
    )
}

function New-PwFixture {
    param([string]$Name = ('fx' + [guid]::NewGuid().ToString('n').Substring(0, 6)), [object[]]$Tasks = (Get-FxDefaultTasks))
    $root = Join-Path $TestDrive $Name
    $fx = [pscustomobject]@{
        Root = $root; Origin = (Join-Path $root 'origin.git'); Base = (Join-Path $root 'base'); Maint = (Join-Path $root 'maint')
        Work = (Join-Path $root 'work'); Registry = (Join-Path $root 'registry'); Evidence = (Join-Path $root 'evidence')
        Outside = (Join-Path $root 'outside'); Catalog = (Join-Path $root 'catalog'); Gh = (Join-Path $root 'gh.json'); Ledger = (Join-Path $root 'ledger.json')
        Sentinels = @('cargo', 'benchmark', 'live-install', 'docker-volumes') | ForEach-Object { Join-Path $root "sentinels\$_" }
    }
    New-Item -ItemType Directory -Force -Path $root, $fx.Work | Out-Null
    foreach ($s in @($fx.Sentinels) + @($fx.Outside)) { Write-FxFile (Join-Path $s 'keep.txt') "protected $s" }
    Invoke-Fx $root init -q --bare -b main $fx.Origin | Out-Null
    $seed = Join-Path $root 'seed'
    Invoke-Fx $root clone -q $fx.Origin $seed | Out-Null
    foreach ($r in @($seed)) { Invoke-Fx $r config user.name fx | Out-Null; Invoke-Fx $r config user.email fx@example.invalid | Out-Null }
    Write-FxFile (Join-Path $seed 'a.txt') "alpha`n"
    Write-FxFile (Join-Path $seed 'notes.txt') "notes`n"
    Write-FxFile (Join-Path $seed 'shared.txt') ((1..10 | ForEach-Object { "line $_" }) -join "`n")
    Write-FxFile (Join-Path $seed '.gitignore') "*.log`n"
    Invoke-Fx $seed add -A | Out-Null
    Invoke-Fx $seed commit -q -m init | Out-Null
    Invoke-Fx $seed push -q origin main | Out-Null
    foreach ($r in @($fx.Base, $fx.Maint)) {
        Invoke-Fx $root clone -q $fx.Origin $r | Out-Null
        Invoke-Fx $r config user.name fx | Out-Null; Invoke-Fx $r config user.email fx@example.invalid | Out-Null
    }
    # Pre-existing user state in the base clone: modified tracked, untracked and ignored files.
    Write-FxFile (Join-Path $fx.Base 'notes.txt') "notes`nuser edit`n"
    Write-FxFile (Join-Path $fx.Base 'user-untracked.txt') "mine`n"
    Write-FxFile (Join-Path $fx.Base 'user.log') "ignored but mine`n"
    [IO.File]::WriteAllText($fx.Ledger, ([pscustomobject]@{ tasks = @($Tasks) } | ConvertTo-Json -Depth 10))
    [IO.File]::WriteAllText($fx.Gh, '{}')
    Initialize-PwRegistry -Registry $fx.Registry -Evidence $fx.Evidence -WorkRoot $fx.Work -BaseClone $fx.Base `
        -Repo 'fx/repo' -LedgerPath $fx.Ledger -Sentinels $fx.Sentinels -DefaultSentinels @() -Catalog $fx.Catalog
    Set-PwProviders -GitHub (New-FakeGitHub $fx.Gh) -Lab $null
    Set-PwFault $null
    $fx
}

function Get-FxItem($Fx, [string]$Id) { @((Get-PwStatus -Registry $Fx.Registry).Items | Where-Object { $_.id -eq $Id })[0] }
function Get-FxManifest($Fx, [string]$Id) {
    $it = Get-FxItem $Fx $Id
    [IO.File]::ReadAllText((Join-Path $Fx.Registry ("manifests\{0}-attempt-{1}.json" -f $Id, $it.attempt))) | ConvertFrom-Json
}
function Set-FxManifest($Fx, [string]$Id, $M) {
    $it = Get-FxItem $Fx $Id
    [IO.File]::WriteAllText((Join-Path $Fx.Registry ("manifests\{0}-attempt-{1}.json" -f $Id, $it.attempt)), ($M | ConvertTo-Json -Depth 30))
}
# Test-only shortcut for unrelated items' states (e.g. children already complete).
function Set-FxItemState($Fx, [string]$Id, [string]$State) {
    $p = Join-Path $Fx.Registry 'state.json'
    $st = [IO.File]::ReadAllText($p) | ConvertFrom-Json
    @($st.items | Where-Object { $_.id -eq $Id })[0].state = $State
    [IO.File]::WriteAllText($p, ($st | ConvertTo-Json -Depth 30))
}

function Assert-FxOk($R) { if ($R.Status -notin @('OK', 'CLAIMED')) { throw "expected OK, got $($R.Status): $($R.Reason)" } }

# Claim an item, commit work in its worktree, push the branch and walk the review states.
function New-FxReadyItem {
    param($Fx, [string]$Id, [int]$Pr, [string]$Owner = 'worker-a', [int]$Commits = 2, [switch]$TouchShared, [string]$StopAt = 'READY_TO_MERGE')
    $c = Request-PwClaim -Registry $Fx.Registry -Item $Id -Owner $Owner
    Assert-FxOk $c
    $wt = @($c.Data.worktrees)[0].path
    for ($i = 1; $i -le $Commits; $i++) {
        Write-FxFile (Join-Path $wt "src\$($Id.ToLower())\work.txt") (((1..$i) | ForEach-Object { "change $_" }) -join "`n")
        if ($TouchShared -and $i -eq 1) {
            Write-FxFile (Join-Path $wt 'shared.txt') ((1..10 | ForEach-Object { if ($_ -eq 8) { "line 8 by $Id" } else { "line $_" } }) -join "`n")
        }
        Invoke-Fx $wt add -A | Out-Null
        Invoke-Fx $wt commit -q -m "$Id change $i" | Out-Null
    }
    $head = (Invoke-Fx $wt rev-parse HEAD)[0]
    Invoke-Fx $wt push -q origin "HEAD:refs/heads/$($c.Data.branch)" | Out-Null
    Set-FxPr $Fx $Pr ([pscustomobject]@{ url = "https://github.com/fx/repo/pull/$Pr"; state = 'OPEN'; baseRefName = 'main'; headRefOid = $head; mergeCommit = $null })
    $steps = @(
        @{ To = 'IN_PROGRESS'; Actor = $Owner }, @{ To = 'VERIFIED'; Actor = 'tester-t'; Head = $head },
        @{ To = 'REVIEWED'; Actor = 'reviewer-r'; Head = $head }, @{ To = 'PR_OPEN'; Actor = $Owner; Head = $head; Pr = $Pr },
        @{ To = 'READY_TO_MERGE'; Actor = 'coordinator'; Head = $head })
    foreach ($s in $steps) {
        Assert-FxOk (Set-PwState -Registry $Fx.Registry -Item $Id @s)
        if ($s.To -eq $StopAt) { break }
    }
    [pscustomobject]@{ Id = $Id; Head = $head; Branch = $c.Data.branch; Worktree = $wt; Root = $c.Data.root; Pr = $Pr }
}

# Performs a GitHub-style merge into origin/main from the maintainer clone.
function Invoke-FxOriginMerge {
    param($Fx, $Ready, [ValidateSet('merge', 'squash', 'rebase')][string]$Method, [switch]$Intervening, [switch]$Tamper)
    $m = $Fx.Maint
    Invoke-Fx $m fetch -q origin | Out-Null
    Invoke-Fx $m checkout -q -B main origin/main | Out-Null
    if ($Intervening) {
        Write-FxFile (Join-Path $m 'a.txt') "alpha`nintervening`n"
        Write-FxFile (Join-Path $m 'shared.txt') ((1..10 | ForEach-Object { if ($_ -eq 2) { 'line 2 intervening' } else { "line $_" } }) -join "`n")
        Invoke-Fx $m commit -q -am intervening | Out-Null
    }
    $b = "origin/$($Ready.Branch)"
    switch ($Method) {
        'merge' { Invoke-Fx $m merge -q --no-ff -m "Merge $($Ready.Branch)" $b | Out-Null }
        'squash' { Invoke-Fx $m merge -q --squash $b | Out-Null; Invoke-Fx $m commit -q -m "squash $($Ready.Branch)" | Out-Null }
        'rebase' {
            Invoke-Fx $m checkout -q -B rb $b | Out-Null
            Invoke-Fx $m rebase -q main | Out-Null
            Invoke-Fx $m checkout -q main | Out-Null
            Invoke-Fx $m merge -q --ff-only rb | Out-Null
        }
    }
    if ($Tamper) {
        Write-FxFile (Join-Path $m "src\$($Ready.Id.ToLower())\work.txt") "tampered`n"
        Invoke-Fx $m commit -q -a --amend --no-edit | Out-Null
    }
    Invoke-Fx $m push -q origin main | Out-Null
    (Invoke-Fx $m rev-parse HEAD)[0]
}

function Start-FxHiddenProcess([string]$Exe, [string]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo $Exe, $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [Diagnostics.Process]::Start($psi)
}
