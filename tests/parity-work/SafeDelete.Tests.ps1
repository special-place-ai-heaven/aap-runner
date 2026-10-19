# Qualified deletion routine: literal path validation plus handle-relative, no-follow
# deletion. Real NTFS junctions; symlinks when the privilege is available. Pester 5,
# Windows PowerShell 5.1 and PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixture.ps1')
    Import-Module $script:PwModule -Force
    if (-not ('PwTest.Native' -as [type])) {
        Add-Type -Namespace PwTest -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CreateSymbolicLink(string link, string target, int flags);
'@
    }
    function New-Tree([string]$Root, [int]$Dirs = 3, [int]$Files = 3) {
        for ($d = 0; $d -lt $Dirs; $d++) { for ($f = 0; $f -lt $Files; $f++) { Write-FxFile (Join-Path $Root "d$d\sub\f$f.txt") "x$d$f" } }
        Write-FxFile (Join-Path $Root 'top.txt') 'top'
        Get-PwIdentity $Root
    }
    function Get-HoldCode([scriptblock]$Script) {
        try { $null = & $Script; return 'NONE' } catch {
            $e = $_.Exception
            while ($e) { if ($e -is [ParityWork.HoldException]) { $script:LastHold = $e.Message; return $e.Code }; $e = $e.InnerException }
            throw
        }
    }
    function New-Outside([string]$Name) {
        $o = Join-Path $TestDrive $Name
        Write-FxFile (Join-Path $o 'sentinel.txt') 'must survive'
        Write-FxFile (Join-Path $o 'attempt\sentinel.txt') 'decoy must survive'
        $o
    }
}

Describe 'path validation' {
    AfterEach { Remove-FxJunctions }
    BeforeAll {
        $script:b = Join-Path $TestDrive 'boundary'
        $script:s = Join-Path $TestDrive 'boundary\cache'
        Write-FxFile (Join-Path $s 'keep.txt') 'shared cache'
        $script:id = New-Tree (Join-Path $b 'owned')
    }
    It 'rejects <Why>' -TestCases @(
        @{ Why = 'empty path'; P = '' }
        @{ Why = 'drive root'; P = 'C:\' }
        @{ Why = 'parent traversal'; P = '{b}\owned\..\..' }
        @{ Why = 'UNC path'; P = '\\server\share\x' }
        @{ Why = 'device path'; P = '\\?\{b}\owned' }
        @{ Why = 'dot device path'; P = '\\.\{b}\owned' }
        @{ Why = 'alternate stream'; P = '{b}\owned\top.txt:evil' }
        @{ Why = 'wildcard'; P = '{b}\own*' }
        @{ Why = 'forward slashes'; P = '{b}/owned' }
        @{ Why = 'path outside the boundary'; P = '{t}' }
        @{ Why = 'protected sentinel'; P = '{b}\cache' }
        @{ Why = 'path containing a sentinel'; P = '{b}' }
    ) {
        $path = $P.Replace('{b}', $script:b).Replace('{t}', $TestDrive)
        Get-HoldCode { Remove-PwOwnedTree -Path $path -Identity $script:id -Boundary $script:b -Sentinels @($script:s) } | Should -Be 'PATH'
        Test-Path (Join-Path $script:b 'owned\top.txt') | Should -BeTrue
        Test-Path (Join-Path $script:s 'keep.txt') | Should -BeTrue
    }
}

Describe 'reparse points and identity' {
    AfterEach { Remove-FxJunctions }
    It 'HOLDs on a junction at the root and leaves the target unchanged' {
        $out = New-Outside 'o1'
        $root = Join-Path $TestDrive 'r1\attempt'
        $id = New-Tree $root
        Rename-Item $root 'attempt-real'
        New-FxJunction $root $out
        $before = Get-FxTreeHash $out
        Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root } | Should -Be 'REPARSE'
        Get-FxTreeHash $out | Should -Be $before
    }

    It 'HOLDs on a junction at an ancestor even when the target holds a same-named tree' {
        $out = New-Outside 'o2'
        $container = Join-Path $TestDrive 'r2\container'
        $root = Join-Path $container 'attempt'
        $id = New-Tree $root
        Rename-Item $container 'container-real'
        New-FxJunction $container $out
        $before = Get-FxTreeHash $out
        Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root } | Should -Be 'REPARSE'
        Get-FxTreeHash $out | Should -Be $before
    }

    It 'HOLDs on a nested junction before deleting anything' {
        $out = New-Outside 'o3'
        $root = Join-Path $TestDrive 'r3'
        $id = New-Tree $root
        New-FxJunction (Join-Path $root 'd1\sub\link') $out
        $before = Get-FxTreeHash $out
        Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root } | Should -Be 'REPARSE'
        Get-FxTreeHash $out | Should -Be $before
        Test-Path (Join-Path $root 'd0\sub\f0.txt') | Should -BeTrue
    }

    It 'HOLDs on nested file and directory symlinks' {
        $out = New-Outside 'o4'
        $root = Join-Path $TestDrive 'r4'
        $id = New-Tree $root
        $made = [PwTest.Native]::CreateSymbolicLink((Join-Path $root 'd0\dirlink'), $out, 3)
        if (-not $made) { Set-ItResult -Skipped -Because 'symbolic link creation privilege is unavailable'; return }
        $before = Get-FxTreeHash $out
        Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root } | Should -Be 'REPARSE'
        [IO.Directory]::Delete((Join-Path $root 'd0\dirlink'))
        [PwTest.Native]::CreateSymbolicLink((Join-Path $root 'd0\filelink'), (Join-Path $out 'sentinel.txt'), 2) | Should -BeTrue
        Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root } | Should -Be 'REPARSE'
        [IO.File]::Delete((Join-Path $root 'd0\filelink'))
        Get-FxTreeHash $out | Should -Be $before
    }

    It 'HOLDs when the directory at the path is not the registered one' {
        $root = Join-Path $TestDrive 'r5'
        $id = New-Tree $root
        Rename-Item $root 'r5-real'
        $null = New-Tree $root
        Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root } | Should -Be 'IDENTITY'
        Test-Path (Join-Path $root 'top.txt') | Should -BeTrue
    }

    It 'deletes a clean tree, including read-only files, and reports absence' {
        $root = Join-Path $TestDrive 'r6'
        $id = New-Tree $root
        Set-ItemProperty (Join-Path $root 'top.txt') -Name IsReadOnly -Value $true
        Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root | Should -BeTrue
        Test-Path -LiteralPath $root | Should -BeFalse
        Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root | Should -BeFalse
    }

    It 'refuses a non-empty root when emptiness is required' {
        $root = Join-Path $TestDrive 'r7'
        $id = New-Tree $root
        Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root -RequireEmpty } | Should -Be 'NOT_EMPTY'
        Test-Path (Join-Path $root 'top.txt') | Should -BeTrue
    }
}

Describe 'locked targets' {
    AfterEach { Remove-FxJunctions }
    It 'retries at most three times, then HOLDs with partial deletion; a later run finishes' {
        $root = Join-Path $TestDrive 'lock'
        $id = New-Tree $root
        $locked = Join-Path $root 'd1\sub\f1.txt'
        $fs = [IO.File]::Open($locked, 'Open', 'Read', 'Read')   # no FILE_SHARE_DELETE
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Get-HoldCode { Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root -RetryDelayMs 300 } | Should -Be 'SHARING'
            $sw.Elapsed.TotalMilliseconds | Should -BeGreaterOrEqual 900
            $sw.Elapsed.TotalMilliseconds | Should -BeLessThan 10000
            Test-Path $locked | Should -BeTrue
        } finally { $fs.Dispose() }
        Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root -RetryDelayMs 300 | Should -BeTrue
        Test-Path -LiteralPath $root | Should -BeFalse
    }

    It 'uses the specified fifteen-second budget by default' {
        $default = (Get-Command Remove-PwOwnedTree).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'RetryDelayMs' } | ForEach-Object { $_.DefaultValue.Value }
        ($default * 3) | Should -Be 15000
    }
}

Describe 'concurrent substitution during deletion' {
    AfterEach { Remove-FxJunctions }
    BeforeAll {
        # Attacker runspace: repeatedly swaps a directory for a junction to the outside and back.
        $script:attacker = {
            param($ctl, $victim, $target, $stash)
            while ($ctl.run) {
                try { [IO.Directory]::Move($victim, $stash) } catch { $ctl.failed++; continue }
                try {
                    New-Item -ItemType Junction -Path $victim -Target $target -ErrorAction Stop | Out-Null
                    $ctl.swaps++
                    [IO.Directory]::Delete($victim)
                } catch { $ctl.failed++ }
                try { [IO.Directory]::Move($stash, $victim) } catch { $ctl.failed++ }
            }
        }
        function Invoke-Race([string]$Victim, [string]$Target, [string]$Stash, [scriptblock]$Delete) {
            $ctl = [hashtable]::Synchronized(@{ run = $true; swaps = 0; failed = 0 })
            $ps = [powershell]::Create()
            [void]$ps.AddScript($script:attacker).AddArgument($ctl).AddArgument($Victim).AddArgument($Target).AddArgument($Stash)
            $h = $ps.BeginInvoke()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ($ctl.swaps -lt 3 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 1 }
            try { $code = Get-HoldCode $Delete }
            finally {
                $ctl.run = $false
                [void]$ps.EndInvoke($h); $ps.Dispose()
                if ([IO.Directory]::Exists($Victim) -and ((Get-Item -LiteralPath $Victim -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($Victim) }
            }
            [pscustomobject]@{ Code = $code; Swaps = $ctl.swaps; Failed = $ctl.failed }
        }
    }

    It 'never deletes through a descendant swapped for a junction' {
        $out = New-Outside 'race-out'
        $before = Get-FxTreeHash $out
        $swaps = 0; $codes = @()
        for ($round = 0; $round -lt 6; $round++) {
            $root = Join-Path $TestDrive "race-d$round"
            $id = New-Tree $root -Dirs 25 -Files 20
            $r = Invoke-Race (Join-Path $root 'd12') $out (Join-Path $TestDrive "race-stash-$round") {
                Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root -RetryDelayMs 50
            }
            $swaps += $r.Swaps; $codes += $r.Code
            if ($r.Code -eq 'IO') { Write-Host "ancestor race IO hold: $script:LastHold" }
            Get-FxTreeHash $out | Should -Be $before
        }
        Write-Host "descendant race: swaps=$swaps outcomes=$($codes -join ',')"
        $swaps | Should -BeGreaterThan 0
        $codes | ForEach-Object { $_ | Should -BeIn @('NONE', 'REPARSE', 'CHANGED', 'SHARING') }
    }

    It 'never deletes through an ancestor swapped for a junction to a same-named decoy' {
        $decoy = New-Outside 'race-decoy'
        $before = Get-FxTreeHash $decoy
        $swaps = 0; $codes = @()
        for ($round = 0; $round -lt 6; $round++) {
            $container = Join-Path $TestDrive "race-a$round\container"
            $root = Join-Path $container 'attempt'
            $id = New-Tree $root -Dirs 25 -Files 20
            $r = Invoke-Race $container $decoy (Join-Path $TestDrive "race-a$round\stash") {
                Remove-PwOwnedTree -Path $root -Identity $id -Boundary $root -RetryDelayMs 50
            }
            $swaps += $r.Swaps; $codes += $r.Code
            if ($r.Code -eq 'IO') { Write-Host "ancestor race IO hold: $script:LastHold" }
            $r.Code | Should -BeIn @('NONE', 'REPARSE', 'IDENTITY', 'NOT_FOUND', 'SHARING')
            Get-FxTreeHash $decoy | Should -Be $before
        }
        Write-Host "ancestor race: swaps=$swaps outcomes=$($codes -join ',')"
        $swaps | Should -BeGreaterThan 0
    }
}
