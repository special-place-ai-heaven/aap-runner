# Mutation check for the P11 Linux backend (P10's method): every safety check in AapLinBackend.psm1, hvsock-relay.ps1 and
# AapLinBackend.HyperV.psm1 carries '# check:<name>'. For each name this copies supervisor\ (the backend imports
# ..\..\capacity, ..\..\broker and ..\..\network, the shared network check, which its own runner mutates) to a
# temp folder, replaces the condition of every if-statement tagged with that name by $false (found with the PowerShell
# parser, not by text search), and runs the tests tagged <name> against the copy in a child process. A check is covered
# only if at least one of its tests then fails. A control run of every tagged test against an unmutated copy must pass
# first, so a broken copy cannot pass for a killed mutant. Exit 0 when every check is covered.
#   pwsh -File tests/backends/linux/Invoke-AapLinMutations.ps1 [-Name <check>...]
param([string[]]$Name, [string]$One, [string]$ModulePath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

if ($One) {
    # Child: run the tests tagged $One (comma-separated) against the given module and print one line.
    $env:AAP_LINBACKEND_MODULE = $ModulePath
    if ($PSVersionTable.PSVersion.Major -lt 6) { Get-Module Pester | Remove-Module -Force; Import-Module (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester\5.7.1\Pester.psd1') } else { Import-Module Pester -MinimumVersion 5.7.1 }
    $c = New-PesterConfiguration
    $c.Run.Path = $PSScriptRoot
    $c.Run.PassThru = $true
    $c.Filter.Tag = @($One -split ',')
    $c.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $c
    foreach ($t in @($r.Failed)) { "FAILED $($t.ExpandedPath)" }
    "MUTANT $One tests=$($r.TotalCount - $r.NotRunCount - $r.SkippedCount) failed=$($r.FailedCount)"
    exit 0
}

$sources = @(foreach ($f in 'AapLinBackend.psm1', 'hvsock-relay.ps1', 'AapLinBackend.HyperV.psm1') {
        $text = [IO.File]::ReadAllText((Join-Path $repo "supervisor\backends\linux\$f"))
        [pscustomobject]@{ Name = $f; Text = $text; Lines = ($text -split "`n"); Ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null) }
    })
$tagged = @($sources | ForEach-Object { [regex]::Matches($_.Text, '# check:([a-z-]+)') | ForEach-Object { $_.Groups[1].Value } } | Sort-Object -Unique)
$all = $tagged
if ($Name) { $Name = @($Name | ForEach-Object { $_ -split ',' }); $tagged = @($tagged | Where-Object { $Name -contains $_ }) }
$work = Join-Path ([IO.Path]::GetTempPath()) ('p11-mut-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$exe = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
function Invoke-AapLinMutantRun([string]$Tags, [string]$Module) {
    $out = & $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -One $Tags -ModulePath $Module 2>&1
    $m = [regex]::Match(($out -join "`n"), 'MUTANT \S+ tests=(\d+) failed=(\d+)')
    if ($Module -like '*\control\*') { $out | Where-Object { "$_" -like 'FAILED *' } | ForEach-Object { Write-Host "$_" } }
    if (-not $m.Success) { return @(0, 0) }
    @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
}
try {
    # Control: the unmutated copy passes every tagged test.
    $dir = Join-Path $work 'control\supervisor'
    [void][IO.Directory]::CreateDirectory($dir)
    foreach ($sub in 'capacity', 'broker', 'network', 'backends') { Copy-Item -LiteralPath (Join-Path $repo "supervisor\$sub") -Destination (Join-Path $dir $sub) -Recurse }
    $control = Invoke-AapLinMutantRun (@($tagged) -join ',') (Join-Path $dir 'backends\linux\AapLinBackend.psm1')
    Write-Host ('{0,-22} tests={1} failed={2}' -f 'CONTROL', $control[0], $control[1])
    if ($control[0] -eq 0 -or $control[1] -ne 0) { throw "the control run must pass: tests=$($control[0]) failed=$($control[1])" }
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
            [IO.File]::WriteAllText((Join-Path $dir "backends\linux\$($s.Name)"), $mutated, (New-Object Text.UTF8Encoding($false)))
            $lineNos += @($mine | ForEach-Object { "$($s.Name):$_" })
        }
        $res = Invoke-AapLinMutantRun $tag (Join-Path $dir 'backends\linux\AapLinBackend.psm1')
        $verdict = $(if ($res[0] -eq 0) { 'NO-TESTS' } elseif ($res[1] -gt 0) { 'KILLED' } else { 'SURVIVED' })
        $rows.Add([pscustomobject]@{ Check = $tag; Lines = ($lineNos -join ','); Tests = $res[0]; Failed = $res[1]; Verdict = $verdict })
        Write-Host ('{0,-22} {1,-9} tests={2} failed={3}' -f $tag, $verdict, $res[0], $res[1])
        Remove-Item -LiteralPath (Join-Path $work $tag) -Recurse -Force
    }
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
$bad = @($rows | Where-Object { $_.Verdict -ne 'KILLED' })
"MUTATIONS host=$($PSVersionTable.PSVersion) checks=$($rows.Count) of $($all.Count) killed=$($rows.Count - $bad.Count) not_killed=$($bad.Count) $(@($bad | ForEach-Object { "$($_.Check):$($_.Verdict)" }) -join ' ')"
if ($bad.Count) { exit 1 }
exit 0
