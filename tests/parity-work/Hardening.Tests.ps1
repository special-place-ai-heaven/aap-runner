# P00.1: the review follow-ups of the cleanup gate. One Describe per finding; each
# finding's test failed on the unhardened gate (origin/main 1759b63), except the pid-4
# inspection case (already fail-closed there) and the two overlap controls. Fixture
# repositories under $TestDrive only. Pester 5, Windows PowerShell 5.1 and PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:PwModule -Force
    $script:Ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
    $script:HostExe = (Get-Process -Id $PID).Path
    $script:Cli = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\parity-work\parity-work.ps1')).ProviderPath
    $script:SafeTreeCs = (Resolve-Path (Join-Path $PSScriptRoot '..\..\tools\parity-work\SafeTree.cs')).ProviderPath

    function New-Tasks([string[]]$Ids, [string[]]$Tokens = @()) {
        @($Ids | ForEach-Object { [pscustomobject]@{ id = $_; needs = @(); owns = @("w/$($_.ToLower())/**"); tokens = @($Tokens) } })
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
    function Start-FxProcessIn([string]$Exe, [string]$Arguments, [string]$Dir) {
        $psi = New-Object Diagnostics.ProcessStartInfo $Exe, $Arguments
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $Dir
        [Diagnostics.Process]::Start($psi)
    }
    function Get-Sha([string]$Text) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    }
}

AfterAll { Set-PwFault $null }

Describe 'P00.1 budgets enforced at claim' {
    It 'refuses a fourth worker before creating anything' {
        $fx = New-PwFixture -Tasks (New-Tasks 'W1', 'W2', 'W3', 'W4')
        foreach ($id in 'W1', 'W2', 'W3') { (Request-PwClaim -Registry $fx.Registry -Item $id -Owner "worker-$id").Status | Should -Be 'CLAIMED' }
        $r = Request-PwClaim -Registry $fx.Registry -Item 'W4' -Owner 'worker-W4'
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'worker budget'
        Test-Path (Join-Path $fx.Work 'W4') | Should -BeFalse
        (Get-FxItem $fx 'W4').state | Should -Be 'NOT_STARTED'
    }

    It 'refuses a third compile-heavy job' {
        $fx = New-PwFixture -Tasks (New-Tasks 'K1', 'K2', 'K3' -Tokens 'compile')
        foreach ($id in 'K1', 'K2') { (Request-PwClaim -Registry $fx.Registry -Item $id -Owner "worker-$id").Status | Should -Be 'CLAIMED' }
        $r = Request-PwClaim -Registry $fx.Registry -Item 'K3' -Owner 'worker-K3'
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'compile budget'
    }

    It 'refuses a second full suite and a second IO-heavy job' {
        $tasks = @(New-Tasks 'S1', 'S2' -Tokens 'suite') + @(New-Tasks 'I1', 'I2' -Tokens 'io')
        $fx = New-PwFixture -Tasks $tasks
        (Request-PwClaim -Registry $fx.Registry -Item 'S1' -Owner 'worker-s1').Status | Should -Be 'CLAIMED'
        (Request-PwClaim -Registry $fx.Registry -Item 'S2' -Owner 'worker-s2').Reason | Should -Match 'suite budget'
        (Request-PwClaim -Registry $fx.Registry -Item 'I1' -Owner 'worker-i1').Status | Should -Be 'CLAIMED'
        (Request-PwClaim -Registry $fx.Registry -Item 'I2' -Owner 'worker-i2').Reason | Should -Match 'io budget'
    }

    It 'takes the budgets from the ledger and refuses an unknown token' {
        $fx = New-PwFixture -Tasks (New-Tasks 'L1', 'L2')
        [IO.File]::WriteAllText($fx.Ledger, ([pscustomobject]@{ max_concurrent_workers = 1; tasks = @(New-Tasks 'L1', 'L2') } | ConvertTo-Json -Depth 10))
        Import-PwLedger -Registry $fx.Registry -LedgerPath $fx.Ledger
        (Request-PwClaim -Registry $fx.Registry -Item 'L1' -Owner 'worker-l1').Status | Should -Be 'CLAIMED'
        (Request-PwClaim -Registry $fx.Registry -Item 'L2' -Owner 'worker-l2').Reason | Should -Match 'worker budget'
        [IO.File]::WriteAllText($fx.Ledger, ([pscustomobject]@{ tasks = @(New-Tasks 'L3' -Tokens 'gpu') } | ConvertTo-Json -Depth 10))
        { Import-PwLedger -Registry $fx.Registry -LedgerPath $fx.Ledger } | Should -Throw '*unknown token*'
    }

    It 'releases the tokens with the leases at COMPLETE' {
        $fx = New-PwFixture -Tasks (New-Tasks 'R1', 'R2', 'R3', 'R4' -Tokens 'suite')
        $a = New-FxReadyItem $fx 'R1' 7
        (Request-PwClaim -Registry $fx.Registry -Item 'R2' -Owner 'worker-r2').Reason | Should -Match 'suite budget'
        $null = Invoke-FxMergeAndRecord $fx $a
        $null = Invoke-FxCleanupAndVerify $fx 'R1'
        @((Get-FxItem $fx 'R1').held).Count | Should -Be 0
        (Request-PwClaim -Registry $fx.Registry -Item 'R2' -Owner 'worker-r2').Status | Should -Be 'CLAIMED'
    }
}

Describe 'P00.1 registration refused after the merge' {
    It 'refuses every resource registration once MERGED_CLEANUP_REQUIRED is recorded' {
        $fx = New-PwFixture
        $a = New-FxReadyItem $fx 'A' 7
        $src = Join-Path $a.Root 'tmp\late.img'; Write-FxFile $src 'late'
        $null = Invoke-FxMergeAndRecord $fx $a
        $before = [IO.File]::ReadAllText((Join-Path $fx.Registry 'manifests\A-attempt-1.json'))
        { Register-PwProcess -Registry $fx.Registry -Item 'A' -ProcessId $PID } | Should -Throw '*after the merge*'
        { Register-PwLabVm -Registry $fx.Registry -Item 'A' -VmId 'vm-late' } | Should -Throw '*after the merge*'
        { New-PwResourceDir -Registry $fx.Registry -Item 'A' -Name 'late' } | Should -Throw '*after the merge*'
        { Add-PwWorktree -Registry $fx.Registry -Item 'A' -Commit $a.Head } | Should -Throw '*after the merge*'
        { Register-PwAsset -Registry $fx.Registry -Item 'A' -Source $src -Destination (Join-Path $fx.Catalog 'late.img') -AssetOwner o -Retention r -Expiry e } | Should -Throw '*after the merge*'
        [IO.File]::ReadAllText((Join-Path $fx.Registry 'manifests\A-attempt-1.json')) | Should -Be $before
        Test-Path (Join-Path $a.Root 'late') | Should -BeFalse
    }
}

Describe 'P00.1 merge proof tied to the merge shape' {
    BeforeEach { $script:fx = New-PwFixture }

    It 'HOLDs a two-parent merge whose second parent is not the accepted head, even with a matching tree' {
        $a = New-FxReadyItem $fx 'A' 7
        $m = $fx.Maint
        Invoke-Fx $m fetch -q origin | Out-Null
        Invoke-Fx $m checkout -q -B main origin/main | Out-Null
        $fork = (Invoke-Fx $m merge-base main "origin/$($a.Branch)")[0]
        $copy = (Invoke-Fx $m commit-tree "$($a.Head)^{tree}" -p $fork -m 'same tree, other commit')[0]
        Invoke-Fx $m merge -q --no-ff -m 'merge a look-alike' $copy | Out-Null
        Invoke-Fx $m push -q origin main | Out-Null
        Set-FxMergedPr $fx $a (Invoke-Fx $m rev-parse HEAD)[0]
        $r = Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator'
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'second parent'
        (Get-FxItem $fx 'A').hold.after_merge | Should -BeTrue
    }

    It 'HOLDs a single-parent landing that silently reverts an intervening main commit' {
        $a = New-FxReadyItem $fx 'A' 7
        $m = $fx.Maint
        Invoke-Fx $m fetch -q origin | Out-Null
        Invoke-Fx $m checkout -q -B main origin/main | Out-Null
        Write-FxFile (Join-Path $m 'a.txt') "alpha`nintervening`n"
        Invoke-Fx $m commit -q -am intervening | Out-Null
        # One commit whose tree is the reviewed head's: the intervening change is undone.
        Invoke-Fx $m checkout -q $a.Head -- . | Out-Null
        Invoke-Fx $m commit -q -m 'land A (reverting intervening)' | Out-Null
        Invoke-Fx $m push -q origin main | Out-Null
        Set-FxMergedPr $fx $a (Invoke-Fx $m rev-parse HEAD)[0]
        $r = Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator'
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'differs'
    }
}

Describe 'P00.1 git version gate' {
    It 'HOLDs the merge proof when git is older than 2.40 (merge-tree --merge-base)' {
        $fx = New-PwFixture
        $a = New-FxReadyItem $fx 'A' 7
        Set-FxMergedPr $fx $a (Invoke-FxOriginMerge $fx $a 'merge')
        Mock -ModuleName ParityWork Get-PwGitVersion { [version]'2.39.5' }
        $r = Register-PwMerge -Registry $fx.Registry -Item 'A' -Actor 'coordinator'
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match '2\.40'
    }
}

Describe 'P00.1 Invoke-PwGit separates stderr and checks exit codes' {
    It 'keeps stderr out of the parsed output' {
        $fx = New-PwFixture
        $sha = (Invoke-Fx $fx.Base rev-parse HEAD)[0]
        $old = $env:GIT_TRACE
        $env:GIT_TRACE = '1'
        try { $r = InModuleScope ParityWork -Parameters @{ Repo = $fx.Base } { param($Repo) Invoke-PwGit $Repo rev-parse HEAD } }
        finally { $env:GIT_TRACE = $old }
        $r.Code | Should -Be 0
        @($r.Out) | Should -Be @($sha)
        @($r.Err).Count | Should -BeGreaterThan 0
    }

    It 'refuses a claim before registering anything when origin/main does not resolve' {
        $fx = New-PwFixture
        Invoke-Fx $fx.Base config remote.origin.fetch '+refs/heads/none*:refs/remotes/origin/none*' | Out-Null
        Invoke-Fx $fx.Base update-ref -d refs/remotes/origin/main | Out-Null
        $r = Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a'
        $r.Status | Should -Be 'REFUSED'
        $r.Reason | Should -Match 'origin/main'
        (Get-FxItem $fx 'A').state | Should -Be 'NOT_STARTED'
        Test-Path (Join-Path $fx.Work 'A') | Should -BeFalse
    }
}

Describe 'P00.1 dirty inventory uses porcelain -z' {
    It 'hashes renamed and non-ASCII, space-named owner files instead of recording them absent' {
        $fx = New-PwFixture
        Invoke-Fx $fx.Base mv a.txt moved.txt | Out-Null
        $odd = 'odd n' + [char]0x00E4 + 'me.txt'
        Write-FxFile (Join-Path $fx.Base $odd) "odd`n"
        (Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a').Status | Should -Be 'CLAIMED'
        $inv = @((Get-FxManifest $fx 'A').base_inventory_initial)
        $moved = @($inv | Where-Object { $_.entry -like '*moved.txt*' })
        $moved.Count | Should -Be 1
        $moved[0].hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $fx.Base 'moved.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
        $o = @($inv | Where-Object { $_.entry -like "*$odd" })
        $o.Count | Should -Be 1
        $o[0].hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $fx.Base $odd) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

Describe 'P00.1 process start time' {
    BeforeEach {
        $script:fx = New-PwFixture
        $script:procs = New-Object System.Collections.Generic.List[object]
    }
    AfterEach { foreach ($p in $procs) { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) } } }

    It 'HOLDs instead of treating a missing registered start time as PID reuse' {
        $a = New-FxReadyItem $fx 'A' 7
        $p = Start-FxHiddenProcess $script:Ping '-n 120 127.0.0.1'; $procs.Add($p)
        Register-PwProcess -Registry $fx.Registry -Item 'A' -ProcessId $p.Id
        $m = Get-FxManifest $fx 'A'; @($m.processes)[0].start_ticks = ''; Set-FxManifest $fx 'A' $m
        $null = Invoke-FxMergeAndRecord $fx $a
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'start time'
        $p.HasExited | Should -BeFalse
    }

    It 'HOLDs when a registered process cannot be inspected (already fail-closed on main)' {
        $a = New-FxReadyItem $fx 'A' 7
        $m = Get-FxManifest $fx 'A'
        $m.processes = @([pscustomobject]@{ pid = 4; start_ticks = '1'; image = 'C:\fx\owned.exe' })   # System: unreadable without elevation
        Set-FxManifest $fx 'A' $m
        $null = Invoke-FxMergeAndRecord $fx $a
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'PROCESS'
    }
}

Describe 'P00.1 unknown-process scan by working directory' {
    It 'HOLDs before deleting anything when an unregistered process runs with its working directory in the root' {
        $fx = New-PwFixture
        $a = New-FxReadyItem $fx 'A' 7
        $null = Invoke-FxMergeAndRecord $fx $a
        $p = Start-FxProcessIn $script:Ping '-n 120 127.0.0.1' (Join-Path $a.Root 'logs')
        try {
            $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
            $r.Status | Should -Be 'HOLD'
            $r.Reason | Should -Match 'unregistered process'
            Test-Path -LiteralPath (Join-Path $a.Root 'tmp') | Should -BeTrue
            $p.HasExited | Should -BeFalse
        } finally { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) } }
    }
}

Describe 'P00.1 transitive child/parent validation' {
    It 'rejects a child that reaches its parent through <Case>' -TestCases @(
        @{ Case = 'another item'; Tasks = @(
                [pscustomobject]@{ id = 'Q'; needs = @(); owns = @('q/**'); children = @('Q.1') },
                [pscustomobject]@{ id = 'Q.1'; needs = @('Z'); owns = @('q1/**'); parent = 'Q' },
                [pscustomobject]@{ id = 'Z'; needs = @('Q'); owns = @('z/**') }) }
        @{ Case = 'a grandparent'; Tasks = @(
                [pscustomobject]@{ id = 'G'; needs = @(); owns = @('g/**'); children = @('G.1') },
                [pscustomobject]@{ id = 'G.1'; needs = @(); owns = @('g1/**'); parent = 'G'; children = @('G.1.1') },
                [pscustomobject]@{ id = 'G.1.1'; needs = @('G'); owns = @('g11/**'); parent = 'G.1' }) }
    ) {
        $fx = New-PwFixture
        $ledger = Join-Path $fx.Root 'transitive.json'
        [IO.File]::WriteAllText($ledger, ([pscustomobject]@{ tasks = $Tasks } | ConvertTo-Json -Depth 5))
        { Import-PwLedger -Registry $fx.Registry -LedgerPath $ledger } | Should -Throw '*must not depend on its parent*'
        @((Get-PwStatus -Registry $fx.Registry).Items).Count | Should -Be 4
    }
}

Describe 'P00.1 mid-component wildcard overlap' {
    It 'treats <A> and <B> as overlapping: <Expect>' -TestCases @(
        @{ A = 'src/a*'; B = 'src/ab/**'; Expect = $true }
        @{ A = 'src/a*/x/**'; B = 'src/abc/x/y'; Expect = $true }
        @{ A = 'src/x?z.txt'; B = 'src/xyz.txt'; Expect = $true }
        @{ A = 'src/a/**'; B = 'src/b/**'; Expect = $false }
        @{ A = 'src/a/b*'; B = 'src/c/**'; Expect = $false }
    ) {
        InModuleScope ParityWork -Parameters @{ A = $A; B = $B } { param($A, $B) Test-PwOverlap $A $B } | Should -Be $Expect
    }
}

Describe 'P00.1 verifier differs from the cleanup actor' {
    It 'refuses a verifier that ran the cleanup' {
        $fx = New-PwFixture
        $a = New-FxReadyItem $fx 'A' 7
        $null = Invoke-FxMergeAndRecord $fx $a
        (Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'cleaner-c' -RetryDelayMs 100).Status | Should -Be 'CLEANED'
        $v = Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'cleaner-c' -RetryDelayMs 100
        $v.Status | Should -Be 'REFUSED'
        $v.Reason | Should -Match 'cleanup actor'
        (Get-FxItem $fx 'A').state | Should -Be 'MERGED_CLEANUP_REQUIRED'
        (Invoke-PwVerifyCleanup -Registry $fx.Registry -Item 'A' -Verifier 'verifier-v' -RetryDelayMs 100).Status | Should -Be 'COMPLETE'
    }
}

Describe 'P00.1 init' {
    It 'refuses to overwrite an existing configuration' {
        $fx = New-PwFixture
        $cfg = Join-Path $fx.Registry 'config.json'
        $before = [IO.File]::ReadAllText($cfg)
        { Initialize-PwRegistry -Registry $fx.Registry -Evidence $fx.Evidence -WorkRoot $fx.Work -BaseClone $fx.Base `
                -Repo 'fx/repo' -LedgerPath $fx.Ledger -Sentinels @() -DefaultSentinels @() } | Should -Throw '*already initialized*'
        [IO.File]::ReadAllText($cfg) | Should -Be $before
    }

    It 'keeps -DefaultSentinels out of the command line' {
        $d = Join-Path $TestDrive 'cli'
        $ledger = Join-Path $d 'ledger.json'
        Write-FxFile $ledger '{"tasks":[]}'
        $reg = Join-Path $d 'registry'
        $exe = $script:HostExe; $cli = $script:Cli
        $out = & { $ErrorActionPreference = 'Continue'; & $exe -NoProfile -NonInteractive -File $cli init -Registry $reg -Evidence (Join-Path $d 'evidence') `
            -WorkRoot (Join-Path $d 'work') -BaseClone (Join-Path $d 'base') -Repo 'fx/repo' -LedgerPath $ledger -DefaultSentinels 'C:\nothing' 2>&1 }
        $LASTEXITCODE | Should -Not -Be 0
        ($out | Out-String) | Should -Match 'DefaultSentinels'
        Test-Path (Join-Path $reg 'config.json') | Should -BeFalse
    }
}

Describe 'P00.1 receipt carries no owner-file hashes' {
    It 'omits the hashes of the base clone owner files from the durable receipt' {
        $fx = New-PwFixture
        $a = New-FxReadyItem $fx 'A' 7
        $null = Invoke-FxMergeAndRecord $fx $a
        $v = Invoke-FxCleanupAndVerify $fx 'A'
        $text = [IO.File]::ReadAllText((Get-FxItem $fx 'A').receipt.path)
        foreach ($f in 'user-untracked.txt', 'user.log', 'notes.txt') {
            $h = (Get-FileHash -LiteralPath (Join-Path $fx.Base $f) -Algorithm SHA256).Hash.ToLowerInvariant()
            $text | Should -Not -Match $h
        }
        @($v.Data.protected_state.base_clone_after).Count | Should -Be 3
    }
}

Describe 'P00.1 directory identity from the creating handle' {
    It 'HOLDs instead of adopting a directory someone else created before the claim resumed' {
        $fx = New-PwFixture
        Set-PwFault 'claim:root-created'
        { Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a' } | Should -Throw '*PW_FAULT*'
        $stranger = Join-Path $fx.Work 'A\attempt-1\tmp\stranger.txt'
        Write-FxFile $stranger 'not ours'
        $r = Request-PwClaim -Registry $fx.Registry -Item 'A' -Owner 'worker-a'
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'EXISTS'
        Test-Path -LiteralPath $stranger | Should -BeTrue
        @((Get-FxManifest $fx 'A').dirs | Where-Object { $_.name -eq 'tmp' })[0].identity | Should -BeNullOrEmpty
    }
}

Describe 'P00.1 worktree-remove window' {
    It 'HOLDs when the worktree path reappears between its deletion and git worktree remove' {
        $fx = New-PwFixture
        $a = New-FxReadyItem $fx 'A' 7
        $null = Invoke-FxMergeAndRecord $fx $a
        $replica = Join-Path $fx.Root 'replica'
        Copy-Item -LiteralPath $a.Worktree -Destination $replica -Recurse -Force
        Write-FxFile (Join-Path $replica 'someone-elses.txt') 'precious'
        Invoke-Fx $replica update-index --refresh 2>$null | Out-Null
        $wt = $a.Worktree
        Set-PwFault 'cleanup:worktree-deleted:repo' -Action { Copy-Item -LiteralPath $replica -Destination $wt -Recurse -Force }.GetNewClosure()
        $r = Invoke-PwCleanup -Registry $fx.Registry -Item 'A' -Actor 'coordinator' -RetryDelayMs 100
        $r.Status | Should -Be 'HOLD'
        $r.Reason | Should -Match 'reappeared'
        Test-Path -LiteralPath (Join-Path $wt 'someone-elses.txt') | Should -BeTrue
        (Get-PwStatus -Registry $fx.Registry).BarrierClosed | Should -BeTrue
    }
}

Describe 'P00.1 deterministic swap between enumeration and open' {
    AfterEach {
        [ParityWork.SafeTree]::TestHook = $null
        foreach ($j in @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -Directory | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) { [IO.Directory]::Delete($j.FullName) }
    }

    # The swap targets d1\sub, opened relative to the already-open d1 handle. Preflight holds
    # d1 with full sharing, so the swap lands and must be caught on the opened object; the
    # delete pass holds d1 without FILE_SHARE_WRITE/DELETE, so the swap itself must fail.
    It 'swaps a directory for a junction between enumeration and open in the <Phase> pass: <Expect>' -TestCases @(
        @{ Phase = 'preflight'; Expect = 'HOLD, nothing deleted' }, @{ Phase = 'delete'; Expect = 'swap refused, tree deleted' }
    ) {
        $out = Join-Path $TestDrive "swap-out-$Phase"
        Write-FxFile (Join-Path $out 'sentinel.txt') 'must survive'
        $before = Get-FxTreeHash $out
        $root = Join-Path $TestDrive "swap-$Phase"
        foreach ($d in 'd0', 'd1', 'd2') { Write-FxFile (Join-Path $root "$d\sub\f.txt") $d }
        $id = Get-PwIdentity $root
        $victim = Join-Path $root 'd1\sub'
        $fired = [hashtable]::Synchronized(@{ n = 0; swapped = $false })
        $hook = {
            param($point)
            if ($point -eq "${Phase}:d1\sub" -and $fired.n -eq 0) {
                $fired.n++
                try { [IO.Directory]::Move($victim, "$victim-stash") } catch { return }
                New-Item -ItemType Junction -Path $victim -Target $out | Out-Null
                $fired.swapped = $true
            }
        }.GetNewClosure()
        [ParityWork.SafeTree]::TestHook = [Action[string]]$hook
        $code = try { $null = Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root -RetryDelayMs 50; 'NONE' }
        catch { $e = $_.Exception; while ($e -and -not ($e -is [ParityWork.HoldException])) { $e = $e.InnerException }; if ($e) { $e.Code } else { throw } }
        $fired.n | Should -Be 1
        if ($Phase -eq 'preflight') {
            $fired.swapped | Should -BeTrue
            $code | Should -BeIn @('REPARSE', 'CHANGED')
            Test-Path -LiteralPath (Join-Path $root 'd0\sub\f.txt') | Should -BeTrue
        } else {
            $fired.swapped | Should -BeFalse
            $code | Should -Be 'NONE'
            Test-Path -LiteralPath $root | Should -BeFalse
        }
        Get-FxTreeHash $out | Should -Be $before
    }
}

Describe 'P00.1 iterative SafeTree walk' {
    It 'deletes a tree deeper than a small thread stack can recurse' {
        $dir = Join-Path $TestDrive 'deep'
        $script = Join-Path $TestDrive 'deep.ps1'
        $runner = @'
namespace PwDeep {
    public static class Runner {
        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        static extern bool CreateDirectoryW(string path, System.IntPtr security);
        // One level per call through \\?\ (the .NET Framework long-path checks are quadratic).
        public static void MakeDeep(string root, int depth) {
            string p = "\\\\?\\" + root;
            for (int i = 0; i < depth; i++) {
                p += "\\d";
                if (!CreateDirectoryW(p, System.IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
            }
            System.IO.File.WriteAllText(p + "\\leaf.txt", "leaf");
        }
        public static string Run(string path, string identity, int stack) {
            string result = null;
            System.Threading.Thread t = new System.Threading.Thread(delegate () {
                try { result = ParityWork.SafeTree.DeleteTree(path, identity, false) ? "DELETED" : "ABSENT"; }
                catch (System.Exception e) { result = "ERROR " + e.Message; }
            }, stack);
            t.Start(); t.Join();
            return result;
        }
    }
}
'@
        Set-Content -LiteralPath (Join-Path $TestDrive 'runner.cs') -Value $runner -Encoding ASCII
        @"
`$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition (([IO.File]::ReadAllText('$($script:SafeTreeCs)')) + [Environment]::NewLine + [IO.File]::ReadAllText('$(Join-Path $TestDrive 'runner.cs')'))
`$root = '$dir'
[void][IO.Directory]::CreateDirectory(`$root)
`$id = [ParityWork.SafeTree]::GetIdentity(`$root)
[PwDeep.Runner]::MakeDeep(`$root, 3000)
[PwDeep.Runner]::Run(`$root, `$id, 256 * 1024)
"@ | Set-Content -LiteralPath $script -Encoding ASCII
        $exe = $script:HostExe
        $out = & { $ErrorActionPreference = 'Continue'; & $exe -NoProfile -NonInteractive -File $script 2>&1 }
        $code = $LASTEXITCODE
        ($out | Out-String).Trim() | Should -Be 'DELETED'
        $code | Should -Be 0
        Test-Path -LiteralPath $dir | Should -BeFalse
    }
}
