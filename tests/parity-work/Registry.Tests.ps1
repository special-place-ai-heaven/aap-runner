# Registry, ledger lock, claims, leases, transitions, parent/child readiness and the
# global barrier. Fixture repositories under $TestDrive only. Pester 5, Windows
# PowerShell 5.1 and PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:PwModule -Force
    function Get-AttemptRoot($Fx, $Id, $N = 1) { Join-Path $Fx.Work "$Id\attempt-$N" }
    function Get-Leased($Fx) { @((Get-PwStatus -Registry $Fx.Registry).Items | Where-Object { @($_.leases).Count -gt 0 } | ForEach-Object id) }

    # Runs the blocks at the same instant in separate runspaces of this process.
    function Invoke-FxParallel([scriptblock[]]$Blocks) {
        $go = [hashtable]::Synchronized(@{ go = $false })
        $jobs = foreach ($b in $Blocks) {
            $ps = [powershell]::Create()
            [void]$ps.AddScript($b).AddArgument($go).AddArgument($script:PwModule)
            [pscustomobject]@{ Ps = $ps; H = $ps.BeginInvoke() }
        }
        Start-Sleep -Milliseconds 300
        $go.go = $true
        foreach ($j in $jobs) {
            try { $j.Ps.EndInvoke($j.H) } finally { $j.Ps.Dispose() }
        }
    }
}

Describe 'claims' {
    BeforeEach { $script:fx = New-PwFixture }

    It 'claims an item: records origin/main, creates branch, worktree and a registered manifest' {
        $r = Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a'
        $r.Status | Should -Be 'CLAIMED'
        $origin = (Invoke-Fx $fx.Base rev-parse origin/main)[0]
        $m = Get-FxManifest $fx 'A'
        $m.base_sha | Should -Be $origin
        $m.root | Should -Be (Get-AttemptRoot $fx 'A')
        $m.root_identity | Should -Not -BeNullOrEmpty
        @($m.dirs | ForEach-Object { $_.identity }) | Should -Not -Contain $null
        $wt = @($m.worktrees)[0]
        (Invoke-Fx $wt.path rev-parse HEAD)[0] | Should -Be $origin
        (Invoke-Fx $wt.path symbolic-ref HEAD)[0] | Should -Be "refs/heads/$($m.branch)"
        $m.env.TEMP | Should -Be (Join-Path $m.root 'tmp')
        $m.env.CARGO_TARGET_DIR | Should -Be (Join-Path $m.root 'target')
        @($m.base_inventory_initial).Count | Should -Be 3
        (Get-FxItem $fx 'A').state | Should -Be 'CLAIMED'
        Get-Leased $fx | Should -Be @('A')
    }

    It 'refuses before worktree creation when a dependency is not COMPLETE' {
        foreach ($s in @('NOT_STARTED', 'MERGED_CLEANUP_REQUIRED', 'CLEANUP_VERIFIED')) {
            Set-FxItemState $fx 'A' $s
            if ($s -eq 'MERGED_CLEANUP_REQUIRED') { continue }   # that one also closes the barrier; covered below
            $r = Request-PwClaim -Registry $fx.Registry -Item 'C' -Owner 'worker-c'
            $r.Status | Should -Be 'REFUSED'
            $r.Reason | Should -Match 'dependency A is not COMPLETE'
            Test-Path (Get-AttemptRoot $fx 'C') | Should -BeFalse
        }
        Set-FxItemState $fx 'A' 'COMPLETE'
        (Request-PwClaim -Registry $fx.Registry -Item 'C' -Owner 'worker-c').Status | Should -Be 'CLAIMED'
    }

    It 'refuses before worktree creation when ownership overlaps an active lease' {
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'CLAIMED'
        $r = Request-PwClaim -Registry $fx.Registry -Item 'D' -Owner 'worker-d'
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'overlaps active lease'
        Test-Path (Get-AttemptRoot $fx 'D') | Should -BeFalse
        (Request-PwClaim -Registry $fx.Registry -Item 'B' -Owner 'worker-b').Status | Should -Be 'CLAIMED'
    }

    It 'refuses before worktree creation while the global barrier is closed' {
        Set-FxItemState $fx 'A' 'MERGED_CLEANUP_REQUIRED'
        $r = Request-PwClaim -Registry $fx.Registry -Item 'B' -Owner 'worker-b'
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'barrier'
        Test-Path (Get-AttemptRoot $fx 'B') | Should -BeFalse
        (Get-PwStatus -Registry $fx.Registry).BarrierClosed | Should -BeTrue
    }

    It 'HOLDs instead of guessing when an unregistered resource already exists at the attempt root' {
        $root = Get-AttemptRoot $fx 'A'
        Write-FxFile (Join-Path $root 'stray.txt') 'unknown'
        $r = Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a'
        $r.Status | Should -Be 'HOLD'
        (Get-FxItem $fx 'A').state | Should -Be 'HOLD'
        Test-Path (Join-Path $root 'stray.txt') | Should -BeTrue
        (Get-PwStatus -Registry $fx.Registry).BarrierClosed | Should -BeFalse
    }

    It 'rejects resources outside the attempt root or on protected sentinels' {
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'CLAIMED'
        { New-PwResourceDir -Registry $fx.Registry -Item 'A' -Name '..' } | Should -Throw
        { New-PwResourceDir -Registry $fx.Registry -Item 'A' -Name 'a\b' } | Should -Throw
        { Register-PwAsset -Registry $fx.Registry -Item 'A' -Source $fx.Sentinels[0] -Destination (Join-Path $fx.Evidence 'x') -AssetOwner o -Retention r -Expiry e } | Should -Throw
        New-PwResourceDir -Registry $fx.Registry -Item 'A' -Name 'downloads' | Should -Be (Join-Path (Get-AttemptRoot $fx 'A') 'downloads')
    }
}

Describe 'parents and children' {
    BeforeEach {
        $tasks = @(
            [pscustomobject]@{ id = 'EXT'; needs = @(); owns = @('ext/**') },
            [pscustomobject]@{ id = 'P'; needs = @(); owns = @('pp/summary/**'); children = @('P.1', 'P.2') },
            [pscustomobject]@{ id = 'P.1'; needs = @(); owns = @('pp/one/**'); parent = 'P' },
            [pscustomobject]@{ id = 'P.2'; needs = @('EXT'); owns = @('pp/two/**'); parent = 'P' }
        )
        $script:fx = New-PwFixture -Tasks $tasks
        Set-FxItemState $fx 'EXT' 'COMPLETE'
    }

    It 'keeps children dispatchable from external prerequisites while the parent works' {
        (Request-PwClaim -Registry $fx.Registry -Item 'P' -Owner 'worker-p').Status | Should -Be 'CLAIMED'
        (Request-PwClaim -Registry $fx.Registry -Item 'P.1' -Owner 'worker-1').Status | Should -Be 'CLAIMED'
        (Request-PwClaim -Registry $fx.Registry -Item 'P.2' -Owner 'worker-2').Status | Should -Be 'CLAIMED'
    }

    It 'does not let a parent become merge-ready before its required children are merged and cleanup-verified' {
        $p = New-FxReadyItem $fx 'P' 11 -StopAt 'PR_OPEN'
        $r = Set-PwState -Registry $fx.Registry -Item 'P' -To 'READY_TO_MERGE' -Actor 'coordinator' -Head $p.Head
        $r.Status | Should -Be 'REFUSED'
        Set-FxItemState $fx 'P.1' 'MERGED_CLEANUP_REQUIRED'
        Set-FxItemState $fx 'P.2' 'COMPLETE'
        (Set-PwState -Registry $fx.Registry -Item 'P' -To 'READY_TO_MERGE' -Actor 'coordinator' -Head $p.Head).Status | Should -Be 'REFUSED'
        Set-FxItemState $fx 'P.1' 'CLEANUP_VERIFIED'
        (Set-PwState -Registry $fx.Registry -Item 'P' -To 'READY_TO_MERGE' -Actor 'coordinator' -Head $p.Head).Status | Should -Be 'OK'
    }

    It 'rejects a child that depends on its own parent' {
        $bad = @([pscustomobject]@{ id = 'Q'; needs = @(); owns = @('q/**') }, [pscustomobject]@{ id = 'Q.1'; needs = @('Q'); owns = @('q1/**'); parent = 'Q' })
        $ledger = Join-Path $TestDrive 'bad-ledger.json'
        [IO.File]::WriteAllText($ledger, ([pscustomobject]@{ tasks = $bad } | ConvertTo-Json -Depth 5))
        { Import-PwLedger -Registry $fx.Registry -LedgerPath $ledger } | Should -Throw '*must not depend on its parent*'
    }

    It 'applies a ledger revision that expands a NOT_STARTED parent into children' {
        $tasks = @([pscustomobject]@{ id = 'S'; needs = @(); owns = @('ss/summary/**') })
        $fx2 = New-PwFixture -Tasks $tasks
        $rev = @([pscustomobject]@{ id = 'S'; needs = @(); owns = @('ss/summary/**'); children = @('S.1') },
            [pscustomobject]@{ id = 'S.1'; needs = @(); owns = @('ss/one/**'); parent = 'S' })
        $ledger = Join-Path $fx2.Root 'ledger-rev.json'
        [IO.File]::WriteAllText($ledger, ([pscustomobject]@{ tasks = $rev } | ConvertTo-Json -Depth 5))
        Import-PwLedger -Registry $fx2.Registry -LedgerPath $ledger
        @((Get-FxItem $fx2 'S').children) | Should -Be @('S.1')
        $s = New-FxReadyItem $fx2 'S' 21 -StopAt 'PR_OPEN'
        (Set-PwState -Registry $fx2.Registry -Item 'S' -To 'READY_TO_MERGE' -Actor 'coordinator' -Head $s.Head).Status | Should -Be 'REFUSED'
        (Request-PwClaim -Registry $fx2.Registry -Item 'S.1' -Owner 'worker-1').Status | Should -Be 'CLAIMED'
    }

    It 'refuses a ledger revision of an item that has left NOT_STARTED' {
        (Request-PwClaim -Registry $fx.Registry -Item 'P' -Owner 'worker-p').Status | Should -Be 'CLAIMED'
        $rev = @([pscustomobject]@{ id = 'P'; needs = @(); owns = @('pp/other/**'); children = @('P.1', 'P.2') })
        $ledger = Join-Path $TestDrive 'rev-active.json'
        [IO.File]::WriteAllText($ledger, ([pscustomobject]@{ tasks = $rev } | ConvertTo-Json -Depth 5))
        { Import-PwLedger -Registry $fx.Registry -LedgerPath $ledger } | Should -Throw '*while it is CLAIMED*'
        @((Get-FxItem $fx 'P').owns) | Should -Be @('pp/summary/**')
    }

    It 'rejects an item id that could escape a path or an argument: <Id>' -TestCases @(
        @{ Id = '..\evil' }, @{ Id = '-rf' }, @{ Id = 'a/b' }, @{ Id = '' }, @{ Id = ('x' * 65) }
    ) {
        $ledger = Join-Path $TestDrive 'bad-id.json'
        [IO.File]::WriteAllText($ledger, ([pscustomobject]@{ tasks = @([pscustomobject]@{ id = $Id; needs = @(); owns = @('z/**') }) } | ConvertTo-Json -Depth 5))
        { Import-PwLedger -Registry $fx.Registry -LedgerPath $ledger } | Should -Throw '*bad item id*'
        @((Get-PwStatus -Registry $fx.Registry).Items).Count | Should -Be 4
    }

    It 'refuses a child whose ownership overlaps a parent lease' {
        $tasks = @([pscustomobject]@{ id = 'R'; needs = @(); owns = @('rr/**'); children = @('R.1') },
            [pscustomobject]@{ id = 'R.1'; needs = @(); owns = @('rr/one/**'); parent = 'R' })
        $fx2 = New-PwFixture -Tasks $tasks
        (Request-PwClaim -Registry $fx2.Registry -Item 'R' -Owner 'worker-r').Status | Should -Be 'CLAIMED'
        (Request-PwClaim -Registry $fx2.Registry -Item 'R.1' -Owner 'worker-1').Reason | Should -Match 'overlaps'
    }
}

Describe 'transitions' {
    BeforeEach { $script:fx = New-PwFixture }

    It 'rejects illegal transitions, self-verification and self-review' {
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'IN_PROGRESS' -Actor 'x').Status | Should -Be 'REFUSED'
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'CLAIMED'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'VERIFIED' -Actor 'tester' -Head 'abc').Status | Should -Be 'REFUSED'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'IN_PROGRESS' -Actor 'someone-else').Status | Should -Be 'REFUSED'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'IN_PROGRESS' -Actor 'worker-a').Status | Should -Be 'OK'
        # IN_PROGRESS now: the same transition and head differ only in the actor.
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'VERIFIED' -Actor 'worker-a' -Head 'abc').Status | Should -Be 'REFUSED'
        (Get-FxItem $fx 'A').state | Should -Be 'IN_PROGRESS'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'VERIFIED' -Actor 'tester' -Head 'abc').Status | Should -Be 'OK'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'REVIEWED' -Actor 'worker-a' -Head 'abc').Status | Should -Be 'REFUSED'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'REVIEWED' -Actor 'reviewer' -Head 'def').Status | Should -Be 'REFUSED'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'REVIEWED' -Actor 'reviewer' -Head 'abc').Status | Should -Be 'OK'
    }

    It 'never lets anyone set MERGED, CLEANUP_VERIFIED or COMPLETE directly' {
        $null = New-FxReadyItem $fx 'A' 5
        foreach ($to in @('MERGED_CLEANUP_REQUIRED', 'CLEANUP_VERIFIED', 'COMPLETE', 'CLAIMED')) {
            (Set-PwState -Registry $fx.Registry -Item 'A' -To $to -Actor 'worker-a').Status | Should -Be 'REFUSED'
            (Set-PwState -Registry $fx.Registry -Item 'A' -To $to -Actor 'coordinator').Status | Should -Be 'REFUSED'
        }
        (Get-FxItem $fx 'A').state | Should -Be 'READY_TO_MERGE'
    }

    It 'invalidates verification and review when the reviewed head changes' {
        $a = New-FxReadyItem $fx 'A' 5
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'IN_PROGRESS' -Actor 'worker-a').Status | Should -Be 'OK'
        $it = Get-FxItem $fx 'A'
        $it.reviewed_head | Should -BeNullOrEmpty
        $it.verified_head | Should -BeNullOrEmpty
    }

    It 'HOLD carries a reason and recovery owner; only that owner clears a pre-merge hold' {
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'CLAIMED'
        Set-PwHold -Registry $fx.Registry -Item 'A' -Reason 'flaky host' -RecoveryOwner 'coordinator' -Actor 'worker-a'
        $it = Get-FxItem $fx 'A'
        $it.state | Should -Be 'HOLD'
        $it.hold.reason | Should -Be 'flaky host'
        $it.hold.owner | Should -Be 'coordinator'
        (Clear-PwHold -Registry $fx.Registry -Item 'A' -Actor 'worker-a').Status | Should -Be 'REFUSED'
        (Clear-PwHold -Registry $fx.Registry -Item 'A' -Actor 'coordinator').Status | Should -Be 'OK'
        (Get-FxItem $fx 'A').state | Should -Be 'CLAIMED'
    }

    It 'survives a crash mid-write: a leftover temp file never replaces the persisted state' {
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'CLAIMED'
        [IO.File]::WriteAllText((Join-Path $fx.Registry 'state.json.tmp-crashed'), '{"schema":1,"items":[')
        (Get-FxItem $fx 'A').state | Should -Be 'CLAIMED'
        (Set-PwState -Registry $fx.Registry -Item 'A' -To 'IN_PROGRESS' -Actor 'worker-a').Status | Should -Be 'OK'
        (Get-FxItem $fx 'A').state | Should -Be 'IN_PROGRESS'
    }
}

Describe 'crash recovery during claim' {
    BeforeEach { $script:fx = New-PwFixture }

    It 'resumes after a crash at <Point> without a double lease' -TestCases @(
        @{ Point = 'claim:registered' }, @{ Point = 'claim:root-created' }
    ) {
        Set-PwFault $Point
        { Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a' } | Should -Throw '*PW_FAULT*'
        (Get-FxItem $fx 'A').state | Should -Be 'CLAIMED'
        (Get-FxManifest $fx 'A').created | Should -BeFalse
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'CLAIMED'
        (Get-FxManifest $fx 'A').created | Should -BeTrue
        $it = Get-FxItem $fx 'A'
        $it.attempt | Should -Be 1
        @($it.leases) | Should -Be @('src/a/**')
        Get-Leased $fx | Should -Be @('A')
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'REFUSED'
    }
}

Describe 'atomic serialization' {
    BeforeEach { $script:fx = New-PwFixture }

    It 'grants exactly one of two simultaneous overlapping claims' {
        $reg = $fx.Registry
        $mk = { param($id) [scriptblock]::Create(@"
param(`$go, `$mod)
Import-Module `$mod
while (-not `$go.go) { Start-Sleep -Milliseconds 1 }
(Request-PwClaim -Registry '$reg' -Item '$id' -Owner 'worker-$id').Status
"@) }
        $out = @(Invoke-FxParallel @((& $mk 'A'), (& $mk 'D')))
        ($out | Where-Object { $_ -eq 'CLAIMED' }).Count | Should -Be 1
        ($out | Where-Object { $_ -eq 'REFUSED' }).Count | Should -Be 1
        @(Get-Leased $fx).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $fx.Work -Directory).Count | Should -Be 1
    }

    It 'grants exactly one of two simultaneous claims of the same item' {
        $reg = $fx.Registry
        $b = [scriptblock]::Create(@"
param(`$go, `$mod)
Import-Module `$mod
while (-not `$go.go) { Start-Sleep -Milliseconds 1 }
(Request-PwClaim -Registry '$reg' -Item 'B' -Owner 'worker-b').Status
"@)
        $out = @(Invoke-FxParallel @($b, $b))
        ($out | Where-Object { $_ -eq 'CLAIMED' }).Count | Should -Be 1
        (Get-FxItem $fx 'B').attempt | Should -Be 1
    }
}
