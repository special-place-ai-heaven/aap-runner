# Merge proof, cleanup sequence and independent verification against disposable local
# Git repositories (real merge-commit, squash and rebase merges into a fixture origin)
# and fake GitHub/lab providers. Pester 5, Windows PowerShell 5.1 and PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:PwModule -Force
    $script:Fixture = Join-Path $PSScriptRoot 'Fixture.ps1'
    $script:Ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
    if (-not ('PwTest.Native' -as [type])) {
        Add-Type -Namespace PwTest -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CreateSymbolicLink(string link, string target, int flags);
'@
    }

    function New-FxLab {
        $vms = [hashtable]::Synchronized(@{})
        $lab = @{
            Destroy = { param($id) $vms.Remove($id) }.GetNewClosure()
            Exists = { param($id) $vms.ContainsKey($id) }.GetNewClosure()
        }
        [pscustomobject]@{ Vms = $vms; Provider = $lab }
    }
    function Get-Status($Fx) { Get-PwStatus -Registry $Fx.Registry }
    function Get-UserState($Fx) {
        @('notes.txt', 'user-untracked.txt', 'user.log') | ForEach-Object { [IO.File]::ReadAllText((Join-Path $Fx.Base $_)) }
    }
    function Invoke-FxMergeAndRecord($Fx, $Ready, [string]$Method = 'merge') {
        $m = Invoke-FxOriginMerge $Fx $Ready $Method -Intervening
        Set-FxMergedPr $Fx $Ready $m
        $r = Register-PwMerge -Registry $Fx.Registry -Item $Ready.Id -Actor 'coordinator'
        if ($r.Status -ne 'OK') { throw "merge not recorded: $($r.Reason)" }
        $m
    }
    function Invoke-FxCleanupAndVerify($Fx, [string]$Id) {
        $c = Invoke-PwCleanup -Registry $Fx.Registry -Item $Id -Actor 'coordinator' -RetryDelayMs 100
        if ($c.Status -ne 'CLEANED') { throw "cleanup: $($c.Status) $($c.Reason)" }
        $v = Invoke-PwVerifyCleanup -Registry $Fx.Registry -Item $Id -Verifier 'verifier-v' -RetryDelayMs 100
        if ($v.Status -ne 'COMPLETE') { throw "verify: $($v.Status) $($v.Reason)" }
        $v
    }
    function Assert-Preserved($Fx, $Ready) {
        Test-Path -LiteralPath $Ready.Worktree | Should -BeTrue
        (Invoke-Fx $Fx.Base show-ref --verify "refs/heads/$($Ready.Branch)")[0] | Should -Match $Ready.Head
        (Get-Status $Fx).BarrierClosed | Should -BeTrue
    }
}

AfterAll { Set-PwFault $null }

Describe 'merge proof' {
    BeforeEach { $script:fx = New-PwFixture }

    It 'accepts a <Method> merge with intervening commits without original-head ancestry' -TestCases @(
        @{ Method = 'merge' }, @{ Method = 'squash' }, @{ Method = 'rebase' }
    ) {
        $a = New-FxReadyItem $fx 'A' 7 -TouchShared
        $m = Invoke-FxOriginMerge $fx $a $Method -Intervening
        Set-FxMergedPr $fx $a $m
        $r = Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator'
        $r.Status | Should -Be 'OK'
        $r.Data.merge_sha | Should -Be $m
        $r.Data.accepted_head | Should -Be $a.Head
        $r.Data.pr_url | Should -Be 'https://github.com/fx/repo/pull/7'
        $r.Data.origin_main_sha | Should -Be $m
        $r.Data.comparison | Should -Match '^MATCH'
        (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
        (Get-Status $fx).BarrierClosed | Should -BeTrue
        Test-Path (Join-Path $fx.Evidence 'A\attempt-1\merge-proof.json') | Should -BeTrue
        $ancestor = & git -C $fx.Base merge-base --is-ancestor $a.Head origin/main 2>$null; $code = $LASTEXITCODE
        if ($Method -ne 'merge') { $code | Should -Be 1 }
    }

    It 'refuses cleanup and preserves the worktree for <Case>' -TestCases @(
        @{ Case = 'an open pull request' }, @{ Case = 'a closed pull request whose commit landed' }, @{ Case = 'a commit with no pull request stage' }
    ) {
        if ($Case -eq 'a commit with no pull request stage') {
            $a = New-FxReadyItem $fx 'A' 7 -StopAt 'VERIFIED'
            $null = Invoke-FxOriginMerge $fx $a 'rebase'
            (Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'REFUSED'
        } else {
            $a = New-FxReadyItem $fx 'A' 7
            if ($Case -eq 'an open pull request') { Set-FxMergedPr $fx $a $null -State 'OPEN' }
            else { $m = Invoke-FxOriginMerge $fx $a 'rebase'; Set-FxMergedPr $fx $a $m -State 'CLOSED' }
            (Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'NOT_MERGED'
        }
        (Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'REFUSED'
        Test-Path -LiteralPath $a.Worktree | Should -BeTrue
        (Get-FxItem $fx 'A').state | Should -Not -Be 'MERGED_CLEANUP_REQUIRED'
    }

    It 'HOLDs and deletes nothing for <Case>' -TestCases @(
        @{ Case = 'wrong base' }, @{ Case = 'wrong repository' }, @{ Case = 'changed reviewed head' },
        @{ Case = 'merged result differs' }, @{ Case = 'GitHub API failure' }, @{ Case = 'remote fetch failure' },
        @{ Case = 'merge commit not on origin/main (stale API)' }
    ) {
        $a = New-FxReadyItem $fx 'A' 7
        $m = Invoke-FxOriginMerge $fx $a 'squash' -Intervening -Tamper:($Case -eq 'merged result differs')
        switch ($Case) {
            'wrong base' { Set-FxMergedPr $fx $a $m -Base 'release' }
            'wrong repository' { Set-FxMergedPr $fx $a $m -Repo 'other/repo' }
            'changed reviewed head' { Set-FxMergedPr $fx $a $m -Head $m }
            'GitHub API failure' { Set-FxPr $fx 7 'FAIL' }
            'remote fetch failure' { Set-FxMergedPr $fx $a $m; Invoke-Fx $fx.Base remote set-url origin (Join-Path $fx.Root 'missing.git') | Out-Null }
            'merge commit not on origin/main (stale API)' { Set-FxMergedPr $fx $a $a.Head }
            default { Set-FxMergedPr $fx $a $m }
        }
        $r = Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator'
        $r.Status | Should -Be 'HOLD'
        $it = Get-FxItem $fx 'A'
        $it.state | Should -Be 'HOLD'
        $it.hold.after_merge | Should -BeTrue
        (Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'REFUSED'
        Assert-Preserved $fx $a
        (Request-PwClaim -Registry $fx.Registry -Item 'B' -Owner 'worker-b').Reason | Should -Match 'barrier'
    }
}

Describe 'merge observation recovery and external merges' {
    BeforeEach { $script:fx = New-PwFixture }

    It 'reverts a post-merge HOLD from a transient API failure once the PR is seen open, reopening the barrier' {
        $a = New-FxReadyItem $fx 'A' 7 -StopAt 'PR_OPEN'
        Set-FxPr $fx 7 'FAIL'
        (Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'HOLD'
        (Get-FxItem $fx 'A').hold.after_merge | Should -BeTrue
        (Get-Status $fx).BarrierClosed | Should -BeTrue
        Set-FxMergedPr $fx $a $null -State 'OPEN'
        (Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'NOT_MERGED'
        $it = Get-FxItem $fx 'A'
        $it.state | Should -Be 'HOLD'
        $it.hold.after_merge | Should -BeFalse
        (Get-Status $fx).BarrierClosed | Should -BeFalse
        (Clear-PwHold -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'OK'
        (Get-FxItem $fx 'A').state | Should -Be 'PR_OPEN'
        (Request-PwClaim -Registry $fx.Registry -Item 'B' -Owner 'worker-b').Status | Should -Be 'CLAIMED'
    }

    It 'refuses a claim while an open PR is uncertain or was merged unobserved, recording the proven merge' {
        $a = New-FxReadyItem $fx 'A' 7
        Set-FxPr $fx 7 'FAIL'
        $r = Request-PwClaim -Registry $fx.Registry -Item 'B' -Owner 'worker-b'
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'uncertain'
        (Get-FxItem $fx 'A').state | Should -Be 'READY_TO_MERGE'
        Set-FxMergedPr $fx $a (Invoke-FxOriginMerge $fx $a 'squash')
        $r = Request-PwClaim -Registry $fx.Registry -Item 'B' -Owner 'worker-b'
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'unrecorded merge of A'
        Test-Path (Join-Path $fx.Work 'B') | Should -BeFalse
        (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
        (Get-Status $fx).BarrierClosed | Should -BeTrue
    }

    It 'refuses READY_TO_MERGE while another open PR was merged unobserved' {
        $a = New-FxReadyItem $fx 'A' 7 -StopAt 'PR_OPEN'
        $b = New-FxReadyItem $fx 'B' 8 -Owner 'worker-b' -StopAt 'PR_OPEN'
        Set-FxMergedPr $fx $a (Invoke-FxOriginMerge $fx $a 'merge')
        $r = Set-PwState -Registry $fx.Registry -Item 'B' -To 'READY_TO_MERGE' -Actor 'coordinator' -Head $b.Head
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'unrecorded merge of A'
        (Get-FxItem $fx 'B').state | Should -Be 'PR_OPEN'
        (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
    }
}

Describe 'several merges' {
    BeforeEach {
        $tasks = @(Get-FxDefaultTasks | Where-Object { $_.id -ne 'D' }) + @([pscustomobject]@{ id = 'E'; needs = @(); owns = @('src/e/**') })
        $script:fx = New-PwFixture -Tasks $tasks
    }

    It 'serializes simultaneous merge observations and keeps dispatch closed until every merged item is clean' {
        $a = New-FxReadyItem $fx 'A' 7
        $b = New-FxReadyItem $fx 'B' 8 -Owner 'worker-b'
        Set-FxMergedPr $fx $a (Invoke-FxOriginMerge $fx $a 'merge')
        Set-FxMergedPr $fx $b (Invoke-FxOriginMerge $fx $b 'squash')
        $go = [hashtable]::Synchronized(@{ go = $false })
        $jobs = foreach ($id in @('A', 'B')) {
            $ps = [powershell]::Create()
            [void]$ps.AddScript({
                    param($go, $mod, $fixture, $gh, $reg, $id)
                    . $fixture
                    Import-Module $mod
                    Set-PwProviders -GitHub (New-FakeGitHub $gh)
                    while (-not $go.go) { Start-Sleep -Milliseconds 1 }
                    (Register-PwMerge -Registry $reg -Item $id -Actor "observer-$id").Status
                }).AddArgument($go).AddArgument($script:PwModule).AddArgument($script:Fixture).AddArgument($fx.Gh).AddArgument($fx.Registry).AddArgument($id)
            [pscustomobject]@{ Ps = $ps; H = $ps.BeginInvoke() }
        }
        Start-Sleep -Milliseconds 300
        $go.go = $true
        $out = foreach ($j in $jobs) { try { $j.Ps.EndInvoke($j.H) } finally { $j.Ps.Dispose() } }
        @($out) | Should -Be @('OK', 'OK')
        (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
        (Get-FxItem $fx 'B').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
        (Request-PwClaim -Registry $fx.Registry -Item 'E' -Owner 'worker-e').Reason | Should -Match 'barrier'
        (Set-PwState -Registry $fx.Registry -Item 'E' -To 'READY_TO_MERGE' -Actor 'coordinator').Status | Should -Be 'REFUSED'
        $null = Invoke-FxCleanupAndVerify $fx 'A'
        (Request-PwClaim -Registry $fx.Registry -Item 'E' -Owner 'worker-e').Reason | Should -Match 'barrier'
        (Request-PwClaim -Registry $fx.Registry -Item 'C' -Owner 'worker-c').Reason | Should -Match 'barrier'
        $null = Invoke-FxCleanupAndVerify $fx 'B'
        (Get-Status $fx).BarrierClosed | Should -BeFalse
        (Request-PwClaim -Registry $fx.Registry -Item 'C' -Owner 'worker-c').Status | Should -Be 'CLAIMED'
    }
}

Describe 'cleanup and independent verification' {
    BeforeEach {
        $script:fx = New-PwFixture
        $script:lab = New-FxLab
        Set-PwProviders -Lab $lab.Provider
        $script:sentinelsBefore = @($fx.Sentinels | ForEach-Object { Get-FxTreeHash $_ })
        $script:procs = New-Object System.Collections.Generic.List[object]
    }
    AfterEach {
        foreach ($p in $procs) { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) } }
        Set-PwFault $null
    }

    It 'cleans a <Method>-merged attempt end to end and an independent residue scan finds nothing owned' -TestCases @(
        @{ Method = 'merge' }, @{ Method = 'squash' }, @{ Method = 'rebase' }
    ) {
        $a = New-FxReadyItem $fx 'A' 7 -TouchShared
        $p = Start-FxHiddenProcess $script:Ping '-n 120 127.0.0.1'; $procs.Add($p)
        Register-PwProcess -Registry $fx.Registry -Item 'A' -ProcessId $p.Id
        Register-PwLabVm -Registry $fx.Registry -Item 'A' -VmId 'vm-a-1'
        $lab.Vms['vm-a-1'] = $true
        $img = Join-Path $a.Root 'tmp\product.img'
        Write-FxFile $img 'product image bytes'
        $dest = Join-Path $fx.Catalog 'product.img'
        Register-PwAsset -Registry $fx.Registry -Item 'A' -Source $img -Destination $dest -AssetOwner 'image-catalog' -Retention 'rollback generation' -Expiry '2026-12-31'
        $verify = Add-PwWorktree -Registry $fx.Registry -Item 'A' -Commit $a.Head
        $userBefore = Get-UserState $fx
        $m = Invoke-FxMergeAndRecord $fx $a $Method
        $v = Invoke-FxCleanupAndVerify $fx 'A'

        # Exact owned roots, including the item container the claim created, are absent;
        # the shared work root is preserved.
        Test-Path -LiteralPath $a.Root | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fx.Work 'A') | Should -BeFalse
        Test-Path -LiteralPath $fx.Work | Should -BeTrue
        $wtList = (Invoke-Fx $fx.Base worktree list --porcelain) -join "`n"
        $wtList | Should -Not -Match ([regex]::Escape($a.Worktree.Replace('\', '/')))
        $wtList | Should -Not -Match ([regex]::Escape($verify.Replace('\', '/')))
        & git -C $fx.Base show-ref --verify --quiet "refs/heads/$($a.Branch)"; $LASTEXITCODE | Should -Be 1
        (Invoke-Fx $fx.Base ls-remote origin "refs/heads/$($a.Branch)")[0] | Should -Match $a.Head
        $p.HasExited | Should -BeTrue
        $lab.Vms.ContainsKey('vm-a-1') | Should -BeFalse
        Test-Path (Join-Path $fx.Registry 'scratch\A-attempt-1-verify') | Should -BeFalse
        # Base main fast-forwarded with the user's dirty state preserved byte for byte.
        (Invoke-Fx $fx.Base rev-parse HEAD)[0] | Should -Be $m
        Get-UserState $fx | Should -Be $userBefore
        @($fx.Sentinels | ForEach-Object { Get-FxTreeHash $_ }) | Should -Be $sentinelsBefore
        # Retained asset accounted for; durable receipt is complete and recoverable.
        (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower() | Should -Be (@($v.Data.retained_assets)[0].sha256)
        $it = Get-FxItem $fx 'A'
        $it.state | Should -Be 'COMPLETE'
        @($it.leases).Count | Should -Be 0
        (Get-Status $fx).BarrierClosed | Should -BeFalse
        $rec = [IO.File]::ReadAllText($it.receipt.path) | ConvertFrom-Json
        $rec.item | Should -Be 'A'
        $rec.final_reviewed_head | Should -Be $a.Head
        $rec.merge_sha | Should -Be $m
        $rec.pr_url | Should -Be 'https://github.com/fx/repo/pull/7'
        $rec.base_sha | Should -Not -BeNullOrEmpty
        $rec.origin_main_sha | Should -Be $m
        $rec.tested_by | Should -Be 'tester-t'
        $rec.reviewed_by | Should -Be 'reviewer-r'
        $rec.implementer | Should -Be 'worker-a'
        $rec.verifier | Should -Be 'verifier-v'
        @($rec.released_leases) | Should -Be @('src/a/**')
        $ids = @($rec.disposed | ForEach-Object id)
        foreach ($x in @('repo', 'verify', 'tmp', 'target', 'logs', 'root', 'container', 'vm:vm-a-1', 'verifier-scratch')) { $ids | Should -Contain $x }
        @($rec.process_observations | Where-Object { $_.kind -eq 'process' }).result | Should -Match 'stopped; absence observed'
        @($rec.process_observations | Where-Object { $_.kind -eq 'branch' }).result | Should -Match 'local only'
        @($rec.protected_state.base_clone_after).Count | Should -Be 3
        $rec.retained_assets[0].owner | Should -Be 'image-catalog'
        $text = [IO.File]::ReadAllText($it.receipt.path)
        $text | Should -Not -Match '(?i)token|secret|password|private.?key|https://[^/\s"]+@'
    }

    It 'refuses a verifier that is the implementer or that runs inside the attempt root' {
        $a = New-FxReadyItem $fx 'A' 7
        $null = Invoke-FxMergeAndRecord $fx $a
        (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'worker-a').Reason | Should -Match 'different identity'
        Push-Location $a.Worktree
        try { (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v').Reason | Should -Match 'outside the attempt root' }
        finally { Pop-Location }
        (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v').Status | Should -Be 'INCOMPLETE'
        (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
    }

    It 'preserves and HOLDs on <Case>, then resumes once the owner resolves it' -TestCases @(
        @{ Case = 'an untracked worktree file' }, @{ Case = 'an ignored worktree file' }, @{ Case = 'a modified tracked file' },
        @{ Case = 'an unregistered entry in the attempt root' }, @{ Case = 'an unknown process running from the root' }
    ) {
        $a = New-FxReadyItem $fx 'A' 7
        $null = Invoke-FxMergeAndRecord $fx $a
        $evidence = switch ($Case) {
            'an untracked worktree file' { Join-Path $a.Worktree 'notes-by-someone.txt' }
            'an ignored worktree file' { Join-Path $a.Worktree 'debug.log' }
            'a modified tracked file' { Join-Path $a.Worktree 'a.txt' }
            'an unregistered entry in the attempt root' { Join-Path $a.Root 'stray\data.txt' }
            'an unknown process running from the root' { Join-Path $a.Root 'tmp\ping-copy.exe' }
        }
        if ($Case -eq 'an unknown process running from the root') {
            Copy-Item $script:Ping $evidence
            $p = Start-FxHiddenProcess $evidence '-n 120 127.0.0.1'; $procs.Add($p)
        } else { Write-FxFile $evidence "someone else's $Case" }
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        Test-Path -LiteralPath $evidence | Should -BeTrue
        Test-Path -LiteralPath $a.Worktree | Should -BeTrue
        (Get-FxItem $fx 'A').hold.after_merge | Should -BeTrue
        (Get-Status $fx).BarrierClosed | Should -BeTrue
        if ($Case -eq 'an unknown process running from the root') { $p.HasExited | Should -BeFalse; $p.Kill(); [void]$p.WaitForExit(5000) }
        # The owner resolves the ambiguity (here: decides the file is disposable) and cleanup resumes.
        if ($Case -eq 'a modified tracked file') { Invoke-Fx $a.Worktree checkout -- a.txt | Out-Null }
        elseif ($Case -eq 'an unregistered entry in the attempt root') { Remove-Item -LiteralPath (Join-Path $a.Root 'stray') -Recurse }
        else { Remove-Item -LiteralPath $evidence }
        $null = Invoke-FxCleanupAndVerify $fx 'A'
        (Get-FxItem $fx 'A').state | Should -Be 'COMPLETE'
    }

    It 'never kills a reused PID whose start time differs' {
        $a = New-FxReadyItem $fx 'A' 7
        $p = Start-FxHiddenProcess $script:Ping '-n 120 127.0.0.1'; $procs.Add($p)
        Register-PwProcess -Registry $fx.Registry -Item 'A' -ProcessId $p.Id
        $m = Get-FxManifest $fx 'A'
        @($m.processes)[0].start_ticks = '1'
        Set-FxManifest $fx 'A' $m
        $null = Invoke-FxMergeAndRecord $fx $a
        $v = Invoke-FxCleanupAndVerify $fx 'A'
        $p.HasExited | Should -BeFalse
        @($v.Data.process_observations | Where-Object { $_.kind -eq 'process' })[0].result | Should -Match 'pid reused'
    }

    It 'retries a locked target boundedly, HOLDs with the barrier closed, then resumes after release' {
        $a = New-FxReadyItem $fx 'A' 7
        $locked = Join-Path $a.Root 'target\locked.bin'
        Write-FxFile $locked 'in use'
        $null = Invoke-FxMergeAndRecord $fx $a
        $fs = [IO.File]::Open($locked, 'Open', 'Read', 'Read')
        try {
            $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
            $r.Status | Should -Be 'HOLD'
            $r.Reason | Should -Match 'SHARING'
            (Get-Status $fx).BarrierClosed | Should -BeTrue
            Test-Path $locked | Should -BeTrue
        } finally { $fs.Dispose() }
        $null = Invoke-FxCleanupAndVerify $fx 'A'
        Test-Path -LiteralPath $a.Root | Should -BeFalse
    }

    It 'HOLDs when guest teardown is not positively observed, keeping the barrier closed' {
        $a = New-FxReadyItem $fx 'A' 7
        Register-PwLabVm -Registry $fx.Registry -Item 'A' -VmId 'vm-stuck'
        $vms = $lab.Vms; $vms['vm-stuck'] = $true
        Set-PwProviders -Lab @{ Destroy = { param($id) }; Exists = { param($id) $vms.ContainsKey($id) }.GetNewClosure() }
        $null = Invoke-FxMergeAndRecord $fx $a
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 50
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'vm-stuck'
        (Get-Status $fx).BarrierClosed | Should -BeTrue
        Test-Path -LiteralPath $a.Worktree | Should -BeTrue
        Set-PwProviders -Lab $lab.Provider
        $null = Invoke-FxCleanupAndVerify $fx 'A'
        $vms.ContainsKey('vm-stuck') | Should -BeFalse
    }

    It 'HOLDs when fast-forwarding base main would overwrite pre-existing user changes' {
        $a = New-FxReadyItem $fx 'A' 7
        Write-FxFile (Join-Path $fx.Base 'a.txt') "alpha`nthe user's own edit`n"
        $null = Invoke-FxMergeAndRecord $fx $a   # the intervening commit also changes a.txt
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'fast-forward refused'
        [IO.File]::ReadAllText((Join-Path $fx.Base 'a.txt')) | Should -Match "the user's own edit"
        (Get-Status $fx).BarrierClosed | Should -BeTrue
    }

    It 'HOLDs instead of letting the base fast-forward overwrite an ignored owner file' {
        $a = New-FxReadyItem $fx 'A' 7
        $null = Invoke-FxMergeAndRecord $fx $a
        Write-FxFile (Join-Path $fx.Maint 'user.log') "now tracked upstream`n"
        Invoke-Fx $fx.Maint add -f user.log | Out-Null
        Invoke-Fx $fx.Maint commit -q -m 'track user.log' | Out-Null
        Invoke-Fx $fx.Maint push -q origin main | Out-Null
        $before = [IO.File]::ReadAllText((Join-Path $fx.Base 'user.log'))
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'fast-forward refused'
        [IO.File]::ReadAllText((Join-Path $fx.Base 'user.log')) | Should -Be $before
        (Get-Status $fx).BarrierClosed | Should -BeTrue
    }

    It 'refuses an asset destination outside the catalog root or on a protected sentinel' {
        $a = New-FxReadyItem $fx 'A' 7 -StopAt 'IN_PROGRESS'
        $src = Join-Path $a.Root 'tmp\p.img'
        Write-FxFile $src 'x'
        $reg = @{ Registry = $fx.Registry; Item = 'A'; Source = $src; AssetOwner = 'o'; Retention = 'r'; Expiry = 'e' }
        { Register-PwAsset @reg -Destination (Join-Path $fx.Sentinels[0] 'p.img') } | Should -Throw '*outside the registered boundary*'
        $guarded = Join-Path $fx.Catalog 'guarded'
        Initialize-PwRegistry -Registry $fx.Registry -Evidence $fx.Evidence -WorkRoot $fx.Work -BaseClone $fx.Base -Repo 'fx/repo' `
            -LedgerPath $fx.Ledger -Sentinels (@($fx.Sentinels) + @($guarded)) -DefaultSentinels @() -Catalog $fx.Catalog
        { Register-PwAsset @reg -Destination (Join-Path $guarded 'p.img') } | Should -Throw '*protected sentinel*'
        @((Get-FxManifest $fx 'A').assets).Count | Should -Be 0
    }

    It 'HOLDs before copying an asset whose source is reached through a <Case>' -TestCases @(
        @{ Case = 'junction ancestor' }, @{ Case = 'file symlink' }, @{ Case = 'hard link' }
    ) {
        $a = New-FxReadyItem $fx 'A' 7
        $target = Join-Path $fx.Outside 'keep.txt'
        $outsideBefore = Get-FxTreeHash $fx.Outside
        switch ($Case) {
            'junction ancestor' { New-FxJunction (Join-Path $a.Root 'tmp\via') $fx.Outside; $src = Join-Path $a.Root 'tmp\via\keep.txt' }
            'file symlink' {
                $src = Join-Path $a.Root 'tmp\link.img'
                if (-not [PwTest.Native]::CreateSymbolicLink($src, $target, 2)) { Set-ItResult -Skipped -Because 'symbolic link creation privilege is unavailable'; return }
            }
            'hard link' { $src = Join-Path $a.Root 'tmp\hard.img'; New-Item -ItemType HardLink -Path $src -Target $target | Out-Null }
        }
        $dest = Join-Path $fx.Catalog 'product.img'
        try {
            Register-PwAsset -Registry $fx.Registry -Item 'A' -Source $src -Destination $dest -AssetOwner 'image-catalog' -Retention 'r' -Expiry 'e'
            $null = Invoke-FxMergeAndRecord $fx $a
            $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
            $r.Status | Should -Be 'HOLD'
            $r.Reason | Should -Match 'REPARSE|HARDLINK'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Get-FxTreeHash $fx.Outside | Should -Be $outsideBefore
            Test-Path -LiteralPath $a.Worktree | Should -BeTrue
        } finally { Remove-FxJunctions }
    }

    It 'HOLDs and never kills a registered process whose image is on the never-kill denylist' {
        $a = New-FxReadyItem $fx 'A' 7
        $p = Start-FxHiddenProcess $script:Ping '-n 120 127.0.0.1'; $procs.Add($p)
        Register-PwProcess -Registry $fx.Registry -Item 'A' -ProcessId $p.Id
        $m = Get-FxManifest $fx 'A'
        @($m.processes)[0].image | Should -Be $script:Ping
        @($m.processes)[0].image = Join-Path $env:SystemRoot 'System32\wsl.exe'
        Set-FxManifest $fx 'A' $m
        $null = Invoke-FxMergeAndRecord $fx $a
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'denylist'
        $p.HasExited | Should -BeFalse
        (Get-Status $fx).BarrierClosed | Should -BeTrue
    }

    It 'never deletes a protected sentinel, even one placed inside an owned directory' {
        $a = New-FxReadyItem $fx 'A' 7
        $cache = Join-Path $a.Root 'target\shared-cargo-cache'
        Write-FxFile (Join-Path $cache 'registry.bin') 'shared'
        Initialize-PwRegistry -Registry $fx.Registry -Evidence $fx.Evidence -WorkRoot $fx.Work -BaseClone $fx.Base `
            -Repo 'fx/repo' -LedgerPath $fx.Ledger -Sentinels (@($fx.Sentinels) + @($cache)) -DefaultSentinels @()
        $null = Invoke-FxMergeAndRecord $fx $a
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'protected sentinel'
        Test-Path (Join-Path $cache 'registry.bin') | Should -BeTrue
        @($fx.Sentinels | ForEach-Object { Get-FxTreeHash $_ }) | Should -Be $sentinelsBefore
    }

    It 'resumes idempotently after a crash following every persisted step, with no premature COMPLETE' {
        $a = New-FxReadyItem $fx 'A' 7
        $p = Start-FxHiddenProcess $script:Ping '-n 120 127.0.0.1'; $procs.Add($p)
        Register-PwProcess -Registry $fx.Registry -Item 'A' -ProcessId $p.Id
        $null = Invoke-FxMergeAndRecord $fx $a 'squash'
        foreach ($step in @('proof', 'inventory', 'evidence', 'processes', 'lab', 'dirs', 'worktrees', 'branch', 'base-sync')) {
            Set-PwFault "cleanup:$step"
            { Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100 } | Should -Throw '*PW_FAULT*'
            (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
            # Empty attempt directories (or more) remain: the verifier must not pass.
            (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v').Status | Should -Be 'INCOMPLETE'
            (Get-Status $fx).BarrierClosed | Should -BeTrue
        }
        Test-Path -LiteralPath $a.Root | Should -BeTrue
        (Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100).Status | Should -Be 'CLEANED'
        Test-Path -LiteralPath $a.Root | Should -BeFalse
        $scratch = Join-Path $fx.Registry 'scratch\A-attempt-1-verify'
        Set-PwFault 'verify:scratch-created'
        { Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v' -RetryDelayMs 100 } | Should -Throw '*PW_FAULT*'
        Test-Path -LiteralPath $scratch | Should -BeTrue
        (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
        Set-PwFault 'verify:receipt-persisted'
        { Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v' -RetryDelayMs 100 } | Should -Throw '*PW_FAULT*'
        Test-Path -LiteralPath $scratch | Should -BeFalse
        $it = Get-FxItem $fx 'A'
        $it.state | Should -Be 'CLEANUP_VERIFIED'
        @($it.leases) | Should -Be @('src/a/**')
        (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'other-verifier').Status | Should -Be 'REFUSED'
        (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v').Status | Should -Be 'COMPLETE'
        $it = Get-FxItem $fx 'A'
        $it.state | Should -Be 'COMPLETE'
        @($it.leases).Count | Should -Be 0
        @($it.history | Where-Object { $_.to -eq 'COMPLETE' }).Count | Should -Be 1
        $p.HasExited | Should -BeTrue
        (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v').Status | Should -Be 'REFUSED'
    }
}

Describe 'early parent merge' {
    It 'cleans the merged parent attempt but keeps it incomplete and requires a remainder item' {
        $tasks = @([pscustomobject]@{ id = 'P'; needs = @(); owns = @('src/p/**'); children = @('P.1') },
            [pscustomobject]@{ id = 'P.1'; needs = @(); owns = @('src/p1/**'); parent = 'P' },
            [pscustomobject]@{ id = 'N'; needs = @('P'); owns = @('src/n/**') })
        $fx = New-PwFixture -Tasks $tasks
        $p = New-FxReadyItem $fx 'P' 9 -StopAt 'PR_OPEN'
        Set-FxMergedPr $fx $p (Invoke-FxOriginMerge $fx $p 'squash')
        (Register-PwMerge -Registry $fx.Registry -Item 'P' -Actor 'coordinator').Status | Should -Be 'OK'
        (Invoke-PwCleanup -Registry $fx.Registry -Item 'P' -Actor 'coordinator' -RetryDelayMs 100).Status | Should -Be 'CLEANED'
        $v = Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'P' -Verifier 'verifier-v' -RetryDelayMs 100
        $v.Status | Should -Be 'INCOMPLETE'
        $v.Reason | Should -Match 'remainder'
        (Get-Status $fx).BarrierClosed | Should -BeTrue
        $ledger = Join-Path $fx.Root 'ledger-rev.json'
        [IO.File]::WriteAllText($ledger, ([pscustomobject]@{ tasks = @($tasks) + @([pscustomobject]@{ id = 'P.rest'; needs = @(); owns = @('src/p/rest/**'); remainder_of = 'P' }) } | ConvertTo-Json -Depth 5))
        Import-PwLedger -Registry $fx.Registry -LedgerPath $ledger
        (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'P' -Verifier 'verifier-v' -RetryDelayMs 100).Status | Should -Be 'CLEANUP_VERIFIED'
        (Get-FxItem $fx 'P').state | Should -Be 'CLEANUP_VERIFIED'
        (Get-Status $fx).BarrierClosed | Should -BeFalse
        (Request-PwClaim -Registry $fx.Registry -Item 'N' -Owner 'worker-n').Reason | Should -Match 'dependency P is not COMPLETE'
        (Request-PwClaim -Registry $fx.Registry -Item 'P.1' -Owner 'worker-1').Status | Should -Be 'CLAIMED'
    }
}

Describe 'configuration' {
    It 'protects the live install, controller, benchmark, vault, cache and Docker paths by default' {
        $reg = Join-Path $TestDrive 'cfg\registry'
        $ledger = Join-Path $TestDrive 'cfg\ledger.json'
        Write-FxFile $ledger '{"tasks":[]}'
        Initialize-PwRegistry -Registry $reg -Evidence (Join-Path $TestDrive 'cfg\evidence') -WorkRoot (Join-Path $TestDrive 'cfg\work') `
            -BaseClone (Join-Path $TestDrive 'cfg\base') -Repo 'fx/repo' -LedgerPath $ledger
        $s = @(([IO.File]::ReadAllText((Join-Path $reg 'config.json')) | ConvertFrom-Json).sentinels)
        foreach ($p in @('C:\Program Files\aap-runner', 'C:\wsl\aap-runner-supervisor', 'C:\temp\aap-cache-benchmark-2026-10-18',
                'C:\claude-obsidian\primus-cloud', 'C:\ProgramData\Docker', (Join-Path $env:USERPROFILE '.cargo'), (Join-Path $env:USERPROFILE '.rustup'))) {
            $s | Should -Contain $p
        }
        $s | Should -Contain (Join-Path $TestDrive 'cfg\base')
    }

    It 'refuses a registry or evidence store inside the disposable work root' {
        $ledger = Join-Path $TestDrive 'cfg2\ledger.json'
        Write-FxFile $ledger '{"tasks":[]}'
        $w = Join-Path $TestDrive 'cfg2\work'
        { Initialize-PwRegistry -Registry (Join-Path $w 'registry') -Evidence (Join-Path $TestDrive 'cfg2\ev') -WorkRoot $w `
                -BaseClone (Join-Path $TestDrive 'cfg2\base') -Repo 'fx/repo' -LedgerPath $ledger -DefaultSentinels @() } | Should -Throw '*outside the disposable work root*'
    }
}
