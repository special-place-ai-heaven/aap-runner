# Mutation check for the P10 Windows backend (P06's method): every safety check in AapWinBackend.psm1 and
# psdirect-call.ps1 carries '# check:<name>'. For each name this copies supervisor\ (the backend imports ..\..\capacity and ..\..\broker) to a temp
# folder, replaces the condition of every if-statement tagged with that name by $false (found with the PowerShell parser,
# not by text search), and runs the tests tagged <name> against the copy in a child process. A check is covered only if
# at least one of its tests then fails and the child leaves its own TEMP empty. Exit 0 when every check is covered.
#   pwsh -File tests/backends/windows/Invoke-AapWinMutations.ps1 [-Name <check>...]
param([string[]]$Name, [string]$One, [string]$ModulePath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

if ($One) {
    # Child: run the tests tagged $One against the mutated module and print one line.
    $env:AAP_WINBACKEND_MODULE = $ModulePath
    if ($PSVersionTable.PSVersion.Major -lt 6) { Get-Module Pester | Remove-Module -Force; Import-Module (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester\5.7.1\Pester.psd1') } else { Import-Module Pester -MinimumVersion 5.7.1 }
    $c = New-PesterConfiguration
    $c.Run.Path = $PSScriptRoot
    $c.Run.PassThru = $true
    $c.Filter.Tag = $One
    $c.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $c
    "MUTANT $One tests=$($r.TotalCount - $r.NotRunCount - $r.SkippedCount) failed=$($r.FailedCount)"
    exit 0
}

$sources = @(foreach ($f in 'AapWinBackend.psm1', 'psdirect-call.ps1', 'AapWinBackend.HyperV.psm1') {
        $text = [IO.File]::ReadAllText((Join-Path $repo "supervisor\backends\windows\$f"))
        [pscustomobject]@{ Name = $f; Text = $text; Lines = ($text -split "`n"); Ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null) }
    })
$tagged = @($sources | ForEach-Object { [regex]::Matches($_.Text, '# check:([a-z-]+)') | ForEach-Object { $_.Groups[1].Value } } | Sort-Object -Unique)
if ($Name) { $Name = @($Name | ForEach-Object { $_ -split ',' }); $tagged = @($tagged | Where-Object { $Name -contains $_ }) }
$work = Join-Path ([IO.Path]::GetTempPath()) ('p10-mut-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$exe = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
try {
    foreach ($tag in $tagged) {
        $dir = Join-Path $work "$tag\supervisor"
        [void][IO.Directory]::CreateDirectory($dir)
        foreach ($sub in 'capacity', 'broker', 'network', 'backends') { Copy-Item -LiteralPath (Join-Path $repo "supervisor\$sub") -Destination (Join-Path $dir $sub) -Recurse }
        $lineNos = @()
        foreach ($s in $sources) {
            $lines = $s.Lines
            $mine = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "# check:$tag(\s|$)") { $i + 1 } })
            if (-not $mine.Count) { continue }
            $ifs = @($s.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $mine -contains $n.Extent.StartLineNumber }, $true))
            if ($ifs.Count -ne $mine.Count) { throw "check:$tag is tagged on $($mine.Count) lines of $($s.Name) but $($ifs.Count) if-statements start there" }
            $mutated = $s.Text
            foreach ($c in @($ifs | ForEach-Object { $_.Clauses[0].Item1.Extent } | Sort-Object StartOffset -Descending)) {
                $mutated = $mutated.Substring(0, $c.StartOffset) + '$false' + $mutated.Substring($c.EndOffset)
            }
            [IO.File]::WriteAllText((Join-Path $dir "backends\windows\$($s.Name)"), $mutated, (New-Object Text.UTF8Encoding($false)))
            $lineNos += @($mine | ForEach-Object { "$($s.Name):$_" })
        }
        $module = Join-Path $dir 'backends\windows\AapWinBackend.psm1'
        # The child's TEMP (its Pester test drives) is a folder of its own that must be empty when it exits: a mutant that
        # leaves anything behind (a folder only SYSTEM and Administrators may open) is reported, never left in TEMP.
        $tmp = Join-Path $work "$tag\tmp"
        [void][IO.Directory]::CreateDirectory($tmp)
        $saved = @($env:TEMP, $env:TMP)
        try { $env:TEMP = $tmp; $env:TMP = $tmp; $out = & $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -One $tag -ModulePath $module 2>&1 }
        finally { $env:TEMP = $saved[0]; $env:TMP = $saved[1] }
        $m = [regex]::Match(($out -join "`n"), 'MUTANT \S+ tests=(\d+) failed=(\d+)')
        $count = $(if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }); $failed = $(if ($m.Success) { [int]$m.Groups[2].Value } else { 0 })
        $verdict = $(if ([IO.Directory]::GetFileSystemEntries($tmp).Count) { 'LEFTOVER' } elseif ($count -eq 0) { 'NO-TESTS' } elseif ($failed -gt 0) { 'KILLED' } else { 'SURVIVED' })
        $rows.Add([pscustomobject]@{ Check = $tag; Lines = ($lineNos -join ','); Tests = $count; Failed = $failed; Verdict = $verdict })
        Write-Host ('{0,-22} {1,-9} tests={2} failed={3}' -f $tag, $verdict, $count, $failed)
    }
} finally {
    # A LEFTOVER may be undeletable here: say where it is instead of failing before the summary.
    try { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } } catch { Write-Warning "left behind: $work ($($_.Exception.Message))" }
}
$bad = @($rows | Where-Object { $_.Verdict -ne 'KILLED' })
"MUTATIONS host=$($PSVersionTable.PSVersion) checks=$($rows.Count) killed=$($rows.Count - $bad.Count) not_killed=$($bad.Count) $(@($bad | ForEach-Object { "$($_.Check):$($_.Verdict)" }) -join ' ')"
if ($bad.Count) { exit 1 }
exit 0
