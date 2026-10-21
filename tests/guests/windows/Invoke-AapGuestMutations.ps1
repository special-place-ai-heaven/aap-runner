# Mutation check for the P14 guest agent: every safety check in guests\windows\AapGuestAgent.psm1 carries
# '# check:<name>' on the line where its condition starts. For each name this copies guests\windows to a temp folder,
# replaces every condition tagged with that name (an if or elseif clause, found with the PowerShell parser) by $false,
# and runs the tests tagged <name> against the copy in a child process (AAP_GUEST_SRC). A check is covered only if at
# least one of its tests then fails. Exit 0 when every check is covered.
#   pwsh -File tests/guests/windows/Invoke-AapGuestMutations.ps1 [-Name <check>...]
param([string[]]$Name, [string]$One, [string]$Src)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$tests = Join-Path $PSScriptRoot 'GuestAgent.Tests.ps1'

if ($One) {
    # Child: run the tests tagged $One against the mutated copy and print one line.
    $env:AAP_GUEST_SRC = $Src
    if ($PSVersionTable.PSVersion.Major -lt 6) { Import-Module (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester\5.7.1\Pester.psd1') } else { Import-Module Pester -MinimumVersion 5.7.1 }
    $c = New-PesterConfiguration
    $c.Run.Path = $tests
    $c.Run.PassThru = $true
    $c.Filter.Tag = $One
    $c.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $c
    "MUTANT $One tests=$($r.TotalCount - $r.NotRunCount - $r.SkippedCount) failed=$($r.FailedCount)"
    exit 0
}

$file = Join-Path $repo 'guests\windows\AapGuestAgent.psm1'
$text = [IO.File]::ReadAllText($file)
$lines = $text -split "`n"
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
$conditions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] }, $true) | ForEach-Object { $_.Clauses | ForEach-Object { $_.Item1 } })
$tagged = @([regex]::Matches($text, '# check:([a-z-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($Name) { $Name = @($Name | ForEach-Object { $_ -split ',' }); $tagged = @($tagged | Where-Object { $Name -contains $_ }) }
$work = Join-Path ([IO.Path]::GetTempPath()) ('p14-mut-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$exe = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
try {
    foreach ($tag in $tagged) {
        $lineNos = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "# check:$tag(\s|$)") { $i + 1 } })
        $conds = @($conditions | Where-Object { $lineNos -contains $_.Extent.StartLineNumber })
        if ($conds.Count -ne $lineNos.Count) { throw "check:$tag is tagged on $($lineNos.Count) lines but $($conds.Count) conditions start there" }
        $mutated = $text
        foreach ($c in @($conds | ForEach-Object { $_.Extent } | Sort-Object StartOffset -Descending)) {
            $mutated = $mutated.Substring(0, $c.StartOffset) + '$false' + $mutated.Substring($c.EndOffset)
        }
        $dir = Join-Path $work $tag
        [void][IO.Directory]::CreateDirectory($work)
        Copy-Item -LiteralPath (Join-Path $repo 'guests\windows') -Destination $dir -Recurse
        [IO.File]::WriteAllText((Join-Path $dir 'AapGuestAgent.psm1'), $mutated, (New-Object Text.UTF8Encoding($false)))
        $out = & $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -One $tag -Src $dir 2>&1
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
