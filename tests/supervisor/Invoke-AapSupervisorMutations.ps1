# Mutation check for the host supervisor (P06's method): every safety check in supervisor\aap-runner-supervisor.ps1 that
# P12 added carries '# check:<name>'. For each name this copies the script to a temp folder, replaces the condition of
# every if-statement tagged with that name (the first on its line) by $false, found with the PowerShell parser, not by
# text search, and runs the supervisor tests tagged <name> against the copy in a child process. A check is covered only
# if at least one of its tests then fails. Exit 0 when every check is covered.
#   pwsh -File tests/supervisor/Invoke-AapSupervisorMutations.ps1 [-Name <check>...]
param([string[]]$Name, [string]$One, [string]$ScriptPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$target = 'supervisor\aap-runner-supervisor.ps1'
$tests = 'supervisor\supervisor.Tests.ps1'

if ($One) {
    # Child: run the tests tagged $One against the mutated script and print one line.
    $env:AAP_SUPERVISOR_SCRIPT = $ScriptPath
    if ($PSVersionTable.PSVersion.Major -lt 6) { Get-Module Pester | Remove-Module -Force; Import-Module (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester\5.7.1\Pester.psd1') } else { Import-Module Pester -MinimumVersion 5.7.1 }
    $c = New-PesterConfiguration
    $c.Run.Path = Join-Path $repo $tests
    $c.Run.PassThru = $true
    $c.Filter.Tag = $One
    $c.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $c
    "MUTANT $One tests=$($r.TotalCount - $r.NotRunCount - $r.SkippedCount) failed=$($r.FailedCount)"
    exit 0
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('sup-mut-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$exe = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
try {
    $text = [IO.File]::ReadAllText((Join-Path $repo $target))
    $tagged = @([regex]::Matches($text, '# check:([a-z0-9-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($Name) { $names = @($Name | ForEach-Object { $_ -split ',' }); $tagged = @($tagged | Where-Object { $names -contains $_ }) }
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
    $lines = $text -split "`n"
    foreach ($tag in $tagged) {
        $lineNos = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "# check:$tag(\s|$)") { $i + 1 } })
        $ifs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $lineNos -contains $n.Extent.StartLineNumber }, $true) |
                Group-Object { $_.Extent.StartLineNumber } | ForEach-Object { $_.Group | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1 })
        if ($ifs.Count -ne $lineNos.Count) { throw "check:$tag is tagged on $($lineNos.Count) lines but if-statements start on $($ifs.Count) of them" }
        $mutated = $text
        foreach ($c in @($ifs | ForEach-Object { $_.Clauses[0].Item1.Extent } | Sort-Object StartOffset -Descending)) {
            $mutated = $mutated.Substring(0, $c.StartOffset) + '$false' + $mutated.Substring($c.EndOffset)
        }
        $dir = Join-Path $work $tag
        [void][IO.Directory]::CreateDirectory($dir)
        $copy = Join-Path $dir 'aap-runner-supervisor.ps1'
        [IO.File]::WriteAllText($copy, $mutated, (New-Object Text.UTF8Encoding($false)))
        $out = & $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -One $tag -ScriptPath $copy 2>&1
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
