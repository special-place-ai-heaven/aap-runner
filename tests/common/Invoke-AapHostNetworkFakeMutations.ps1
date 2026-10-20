# Mutation check for the shared host network fake (P06's method): every check in AapHostNetworkFake.psm1 carries
# '# check:<name>'. For each name this copies the module to a temp folder, replaces the condition of every if-statement
# tagged with that name by $false (found with the PowerShell parser, not by text search), and runs the tests tagged <name>
# against the copy in a child process. A check is covered only if at least one of its tests then fails. Exit 0 when every
# check is covered.
#   pwsh -File tests/common/Invoke-AapHostNetworkFakeMutations.ps1 [-Name <check>...]
param([string[]]$Name, [string]$One, [string]$ModulePath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$tests = Join-Path $PSScriptRoot 'AapHostNetworkFake.Tests.ps1'

if ($One) {
    # Child: run the tests tagged $One against the mutated module and print one line.
    $env:AAP_NETFAKE_MODULE = $ModulePath
    if ($PSVersionTable.PSVersion.Major -lt 6) { Get-Module Pester | Remove-Module -Force; Import-Module (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester\5.7.1\Pester.psd1') } else { Import-Module Pester -MinimumVersion 5.7.1 }
    $c = New-PesterConfiguration
    $c.Run.Path = $tests
    $c.Run.PassThru = $true
    $c.Filter.Tag = $One
    $c.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $c
    "MUTANT $One tests=$($r.TotalCount - $r.NotRunCount - $r.SkippedCount) failed=$($r.FailedCount)"
    exit 0
}

$text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AapHostNetworkFake.psm1'))
$tagged = @([regex]::Matches($text, '# check:([a-z-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($Name) { $Name = @($Name | ForEach-Object { $_ -split ',' }); $tagged = @($tagged | Where-Object { $Name -contains $_ }) }
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
$lines = $text -split "`n"
$work = Join-Path ([IO.Path]::GetTempPath()) ('netfake-mut-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$exe = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
try {
    foreach ($tag in $tagged) {
        $lineNos = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "# check:$tag(\s|$)") { $i + 1 } })
        $ifs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $lineNos -contains $n.Extent.StartLineNumber }, $true))
        if ($ifs.Count -ne $lineNos.Count) { throw "check:$tag is tagged on $($lineNos.Count) lines but $($ifs.Count) if-statements start there" }
        $mutated = $text
        foreach ($c in @($ifs | ForEach-Object { $_.Clauses[0].Item1.Extent } | Sort-Object StartOffset -Descending)) {
            $mutated = $mutated.Substring(0, $c.StartOffset) + '$false' + $mutated.Substring($c.EndOffset)
        }
        $dir = Join-Path $work $tag
        [void][IO.Directory]::CreateDirectory($dir)
        $module = Join-Path $dir 'AapHostNetworkFake.psm1'
        [IO.File]::WriteAllText($module, $mutated, (New-Object Text.UTF8Encoding($false)))
        $out = & $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -One $tag -ModulePath $module 2>&1
        $m = [regex]::Match(($out -join "`n"), 'MUTANT \S+ tests=(\d+) failed=(\d+)')
        $count = $(if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }); $failed = $(if ($m.Success) { [int]$m.Groups[2].Value } else { 0 })
        $verdict = $(if ($count -eq 0) { 'NO-TESTS' } elseif ($failed -gt 0) { 'KILLED' } else { 'SURVIVED' })
        $rows.Add([pscustomobject]@{ Check = $tag; Lines = ($lineNos -join ','); Tests = $count; Failed = $failed; Verdict = $verdict })
    }
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
$rows | Format-Table -AutoSize | Out-String -Width 200
$bad = @($rows | Where-Object { $_.Verdict -ne 'KILLED' })
"MUTATIONS host=$($PSVersionTable.PSVersion) checks=$($rows.Count) killed=$($rows.Count - $bad.Count) not_killed=$($bad.Count)"
if ($bad.Count) { exit 1 }
exit 0
