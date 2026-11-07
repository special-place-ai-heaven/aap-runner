# P12.2: orphan aap-wbuild-* build VMs after a builder crash. The image builder (images\windows\AapWinImage.psm1) holds
# <staging>\build\<build id>.lock (FileShare.None, never deleted) from before NewVm until it exits; a VM whose lock nobody
# holds belongs to a dead builder. Remove-AapWinOrphanBuildVm stops and removes such a VM by id and detaches its network.
# Same file-backed fakes as the other backend tests (nothing here calls Hyper-V). Pester 5, Windows PowerShell 5.1 and
# PowerShell 7.5+.

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinBackendTestHelpers.ps1')
    Import-Module $script:CapModule -Force
    Import-Module $script:BackendModule -Force

    $script:BuildId = 'win25-vs2026-x64_20261007.264.1-aap.1'

    # The builder's tag: the first 8 hex of the SHA-256 of the build id (AapWinImage.psm1, Get-AapWinNames).
    function Get-BuildTag([string]$BuildId) { (Get-WinSha ([Text.Encoding]::UTF8.GetBytes($BuildId))).Substring(0, 8) }

    function New-BuildWorld {
        $w = New-WinWorld
        [pscustomobject]@{ W = $w; B = (New-WinBackend $w); Build = (Join-Path $w.Base 'staging\build') }
    }

    # A build VM the way the builder leaves it: created Off, attached through the network module, then Running when the
    # builder dies. -Lock writes <build id>.lock (a crashed builder's lock file: present, held by nobody).
    function Add-BuildVm($X, [string]$Name, [string]$BuildId = '', [string]$State = 'Running', [switch]$Lock, [switch]$NoAttach) {
        $w = $X.W
        $id = [guid]::NewGuid().ToString()
        $cfg = Join-Path $w.Scratch "vm-$id"
        [void][IO.Directory]::CreateDirectory((Join-Path $cfg 'Virtual Machines'))
        [IO.File]::WriteAllText((Join-Path $cfg "Virtual Machines\$id.vmcx"), 'fake vm configuration')
        $vm = [pscustomobject][ordered]@{ Id = $id; Name = $Name; State = 'Off'; Cpus = 4; MemGib = 10; ConfigurationLocation = $cfg; Disks = @(); Adapters = @() }
        Save-WinVms $w (@(Get-WinVms $w) + $vm)
        if (-not $NoAttach -and $Name -cmatch '^aap-wbuild-[0-9a-f]{8}\z') { $null = & (Get-WinNet $w).Attach @{ VmId = $id; VmName = $Name; Profile = 'windows' } }
        $all = @(Get-WinVms $w); foreach ($v in $all) { if ($v.Id -eq $id) { $v.State = $State } }; Save-WinVms $w $all
        if ($Lock) {
            [void][IO.Directory]::CreateDirectory($X.Build)
            [IO.File]::WriteAllText((Join-Path $X.Build "$BuildId.lock"), '')
        }
        $id
    }
}

Describe 'orphan build VMs' {
    It 'a build VM whose lock nobody holds is stopped, removed by id and detached' -Tag 'build-orphan' {
        $x = New-BuildWorld; $w = $x.W
        $name = 'aap-wbuild-' + (Get-BuildTag $script:BuildId)
        $id = Add-BuildVm $x $name $script:BuildId -Lock
        @(Get-WinNetRecords $w).Count | Should -Be 1
        $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be $name
        $r[0].Action | Should -Be 'removed'
        @(Get-WinVms $w).Count | Should -Be 0
        @(Get-WinNetRecords $w).Count | Should -Be 0
        @(Get-WinCalls $w | Where-Object { $_ -match '^(StopVm|RemoveVm|NetDetach) ' }) | Should -Be @("StopVm $id", "RemoveVm $id", "NetDetach $id")
        # The builder's next run takes the same lock file: it stays.
        [IO.File]::Exists((Join-Path $x.Build "$($script:BuildId).lock")) | Should -BeTrue
        @(Remove-AapWinOrphanBuildVm -Backend $x.B).Count | Should -Be 0
    }

    It 'an Off orphan is not stopped, only removed and detached' -Tag 'build-orphan' {
        $x = New-BuildWorld; $w = $x.W
        $id = Add-BuildVm $x ('aap-wbuild-' + (Get-BuildTag $script:BuildId)) $script:BuildId -State 'Off' -Lock
        $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
        $r[0].Action | Should -Be 'removed'
        @(Get-WinCalls $w 'StopVm *').Count | Should -Be 0
        @(Get-WinCalls $w 'RemoveVm *') | Should -Be @("RemoveVm $id")
        @(Get-WinNetRecords $w).Count | Should -Be 0
    }

    It 'a build VM with no matching lock file is left alone and reported unmatched' -Tag 'build-unmatched' {
        $x = New-BuildWorld; $w = $x.W
        # Another build's lock exists, so the folder is listed, but none carries this VM's tag.
        [void](Add-BuildVm $x ('aap-wbuild-' + (Get-BuildTag 'other-build')) 'other-build' -Lock)
        [void](Add-BuildVm $x ('aap-wbuild-' + (Get-BuildTag $script:BuildId)) $script:BuildId -NoAttach)
        $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
        $r.Count | Should -Be 2
        @($r | Where-Object { $_.Name -eq 'aap-wbuild-' + (Get-BuildTag 'other-build') })[0].Action | Should -Be 'removed'
        $u = @($r | Where-Object { $_.Name -eq 'aap-wbuild-' + (Get-BuildTag $script:BuildId) })[0]
        $u.Action | Should -Be 'unmatched'
        $u.Detail | Should -Match 'no lock file'
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinCalls $w 'StopVm *').Count | Should -Be 1
        @(Get-WinCalls $w 'RemoveVm *').Count | Should -Be 1
    }

    It 'an absent build folder removes nothing and reports every build VM unmatched' -Tag 'build-unmatched' {
        $x = New-BuildWorld; $w = $x.W
        [void](Add-BuildVm $x ('aap-wbuild-' + (Get-BuildTag $script:BuildId)) $script:BuildId)
        $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
        $r.Count | Should -Be 1
        $r[0].Action | Should -Be 'unmatched'
        @(Get-WinVms $w).Count | Should -Be 1
        @(Get-WinNetRecords $w).Count | Should -Be 1
        @(Get-WinCalls $w | Where-Object { $_ -match '^(StopVm|RemoveVm|NetDetach) ' }).Count | Should -Be 0
    }

    It 'a build VM whose lock a builder holds is left alone until it lets go' -Tag 'build-lock' {
        $x = New-BuildWorld; $w = $x.W
        $name = 'aap-wbuild-' + (Get-BuildTag $script:BuildId)
        $id = Add-BuildVm $x $name $script:BuildId -Lock
        $held = [IO.File]::Open((Join-Path $x.Build "$($script:BuildId).lock"), 'Open', 'ReadWrite', 'None')
        try {
            $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
            $r.Count | Should -Be 1
            $r[0].Action | Should -Be 'held'
            @(Get-WinVms $w).Count | Should -Be 1
            @(Get-WinNetRecords $w).Count | Should -Be 1
            @(Get-WinCalls $w 'StopVm *').Count | Should -Be 0
            @(Get-WinCalls $w 'RemoveVm *').Count | Should -Be 0
            @(Get-WinCalls $w 'NetDetach *').Count | Should -Be 0
        } finally { $held.Dispose() }
        @(Remove-AapWinOrphanBuildVm -Backend $x.B)[0].Action | Should -Be 'removed'
        @(Get-WinVms $w).Count | Should -Be 0
    }

    It 'holds the lock while it removes, so a builder starting meanwhile gets AAP_BuildBusy' -Tag 'build-lock' {
        $x = New-BuildWorld; $w = $x.W
        $id = Add-BuildVm $x ('aap-wbuild-' + (Get-BuildTag $script:BuildId)) $script:BuildId -Lock
        $path = Join-Path $x.Build "$($script:BuildId).lock"
        $w | Add-Member -NotePropertyName Probe -NotePropertyValue $path -Force
        $w | Add-Member -NotePropertyName Opened -NotePropertyValue $null -Force
        $x.B.Provider.RemoveVm = { param($a)
            try { [IO.File]::Open($w.Probe, 'Open', 'ReadWrite', 'None').Dispose(); $w.Opened = $true } catch [IO.IOException] { $w.Opened = $false }
            Save-WinVms $w @(Get-WinVms $w | Where-Object { $_.Id -ne $a.VmId })
        }
        @(Remove-AapWinOrphanBuildVm -Backend $x.B)[0].Action | Should -Be 'removed'
        $w.Opened | Should -BeFalse
    }

    It 'touches no VM that is not exactly aap-wbuild- and 8 lowercase hex digits' -Tag 'build-name' {
        $x = New-BuildWorld; $w = $x.W
        $tag = Get-BuildTag $script:BuildId
        $others = @("aap-w-1-$tag", "aap-wverify-$tag", "aap-l-1-$tag", "aap-wbuild-$($tag.ToUpperInvariant())", "aap-wbuild-${tag}0", "xaap-wbuild-$tag", 'aap-wbuild-', 'some-user-vm')
        foreach ($n in $others) { [void](Add-BuildVm $x $n $script:BuildId -Lock) }
        $mine = Add-BuildVm $x "aap-wbuild-$tag" $script:BuildId -Lock
        $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be "aap-wbuild-$tag"
        @(Get-WinVms $w | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @($others | Sort-Object)
        @(Get-WinCalls $w 'RemoveVm *') | Should -Be @("RemoveVm $mine")
        @(Get-WinCalls $w 'StopVm *') | Should -Be @("StopVm $mine")
    }

    It 'reports a VM that will not go and keeps its network; the others still go' -Tag 'build-fail' {
        $x = New-BuildWorld; $w = $x.W
        $a = 'aap-wbuild-' + (Get-BuildTag 'build-a'); $b = 'aap-wbuild-' + (Get-BuildTag 'build-b')
        [void](Add-BuildVm $x $a 'build-a' -Lock); $idB = Add-BuildVm $x $b 'build-b' -Lock -NoAttach   # the fake switch carries one build VM
        $w | Add-Member -NotePropertyName StuckName -NotePropertyValue $a -Force
        $x.B.Provider.RemoveVm = { param($a2)
            $v = @(Get-WinVms $w | Where-Object { $_.Id -eq $a2.VmId })[0]
            if ($v.Name -eq $w.StuckName) { throw 'fake: Remove-VM failed' }
            Save-WinVms $w @(Get-WinVms $w | Where-Object { $_.Id -ne $a2.VmId })
        }
        $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
        $r.Count | Should -Be 2
        $fail = @($r | Where-Object { $_.Name -eq $a })[0]
        $fail.Action | Should -Be 'failed'
        $fail.Detail | Should -Match 'Remove-VM failed'
        @($r | Where-Object { $_.Name -eq $b })[0].Action | Should -Be 'removed'
        @(Get-WinVms $w | ForEach-Object { $_.Name }) | Should -Be @($a)
        @(Get-WinNetRecords $w).Count | Should -Be 1
        @(Get-WinCalls $w 'NetDetach *') | Should -Be @("NetDetach $idB")
    }

    It 'reports a Detach that fails, naming the VM that is already gone' -Tag 'build-fail' {
        $x = New-BuildWorld; $w = $x.W
        [void](Add-BuildVm $x ('aap-wbuild-' + (Get-BuildTag $script:BuildId)) $script:BuildId -Lock)
        Set-WinNet $w -Fail 'DetachAfterNeighbor'
        $r = @(Remove-AapWinOrphanBuildVm -Backend $x.B)
        $r[0].Action | Should -Be 'failed'
        $r[0].Detail | Should -Match 'Detach'
        @(Get-WinVms $w).Count | Should -Be 0
        @(Get-WinNetRecords $w).Count | Should -Be 1
    }

    It 'a VM listing error throws and touches nothing' -Tag 'build-list' {
        $x = New-BuildWorld; $w = $x.W
        [void](Add-BuildVm $x ('aap-wbuild-' + (Get-BuildTag $script:BuildId)) $script:BuildId -Lock)
        Set-WinKnob $w @{ ListFails = $true }
        { Remove-AapWinOrphanBuildVm -Backend $x.B } | Should -Throw '*Get-VM failed*'
        @(Get-WinCalls $w 'RemoveVm *').Count | Should -Be 0
    }

    It 'reads staging_root from the storage document, else base_root\staging' -Tag 'build-list' {
        $x = New-BuildWorld; $w = $x.W
        $x.B.Storage.StagingPath | Should -Be (Join-Path $w.Base 'staging')
        $doc = Read-WinJson $w.StoragePath $null
        $custom = Join-Path $w.Root 'roots\staging'
        $doc.roots.staging_root = [pscustomobject]@{ path = $custom; volume_guid = $script:VolGuid }
        Write-WinJson $w.StoragePath $doc
        (New-WinBackend $w).Storage.StagingPath | Should -Be $custom
    }
}
