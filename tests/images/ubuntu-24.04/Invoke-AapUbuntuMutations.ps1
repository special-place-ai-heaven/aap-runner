# Mutation check for the P07 builder: every safety check in AapUbuntuImage.psm1 carries '# check:<name>'. For each name this
# copies images\ubuntu-24.04 (and the P06 helpers it loads) to a temp folder, replaces the condition of every if-statement
# tagged with that name by $false (found with the PowerShell parser, not by text search), and runs the tests tagged <name>
# against the copy in a child process. A check is covered only if at least one of its tests then fails. A control run of the
# same tests against the unmutated copy must pass first, so a test that fails for another reason cannot count as a kill.
# Exit 0 when every check is covered.
#   pwsh -File tests/images/ubuntu-24.04/Invoke-AapUbuntuMutations.ps1 [-Name <check>...]
param([string[]]$Name, [string]$One, [string]$ModulePath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$tests = Join-Path $PSScriptRoot 'UbuntuImage.Tests.ps1'

if ($One) {
    # Child: run the tests tagged $One (all of them when $One is '*') against the module at $ModulePath and print one line.
    # The tests run as CI runs them: without this script's strict mode and stop-on-error preference.
    Set-StrictMode -Off
    $ErrorActionPreference = 'Continue'
    $env:AAP_UBUNTUIMAGE_MODULE = $ModulePath
    if ($PSVersionTable.PSVersion.Major -lt 6) { Import-Module (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester\5.7.1\Pester.psd1') } else { Import-Module Pester -MinimumVersion 5.7.1 }
    $c = New-PesterConfiguration
    $c.Run.Path = $tests
    $c.Run.PassThru = $true
    if ($One -ne '*') { $c.Filter.Tag = @($One -split ',') }
    $c.Output.Verbosity = 'None'
    $r = Invoke-Pester -Configuration $c
    "MUTANT $One tests=$($r.TotalCount - $r.NotRunCount - $r.SkippedCount) failed=$($r.FailedCount)"
    exit 0
}

$source = Join-Path $repo 'images\ubuntu-24.04\AapUbuntuImage.psm1'
$text = [IO.File]::ReadAllText($source)
$tagged = @([regex]::Matches($text, '# check:([a-z-]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($Name) { $Name = @($Name | ForEach-Object { $_ -split ',' }); $tagged = @($tagged | Where-Object { $Name -contains $_ }) }
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
$lines = $text -split "`n"
$work = Join-Path ([IO.Path]::GetTempPath()) ('p07-mut-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
$exe = (Get-Process -Id $PID).Path
$rows = New-Object System.Collections.Generic.List[object]
function New-Copy([string]$Dir, [string]$ModuleText) {
    [void][IO.Directory]::CreateDirectory((Join-Path $Dir 'images'))
    foreach ($d in 'ubuntu-24.04', 'windows') { Copy-Item -LiteralPath (Join-Path $repo "images\$d") -Destination (Join-Path $Dir "images\$d") -Recurse }
    $module = Join-Path $Dir 'images\ubuntu-24.04\AapUbuntuImage.psm1'
    [IO.File]::WriteAllText($module, $ModuleText, (New-Object Text.UTF8Encoding($false)))
    return $module
}
function Invoke-Child([string]$Tags, [string]$Module) {
    $out = & $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -One $Tags -ModulePath $Module 2>&1
    $m = [regex]::Match(($out -join "`n"), 'MUTANT \S+ tests=(\d+) failed=(\d+)')
    if (-not $m.Success) { return [pscustomobject]@{ Tests = 0; Failed = 0 } }
    [pscustomobject]@{ Tests = [int]$m.Groups[1].Value; Failed = [int]$m.Groups[2].Value }
}
try {
    $control = Invoke-Child ($tagged -join ',') (New-Copy (Join-Path $work 'control') $text)
    "CONTROL tests=$($control.Tests) failed=$($control.Failed)"
    if ($control.Tests -eq 0 -or $control.Failed -ne 0) { throw 'the tagged tests do not pass against the unmutated copy; no mutant result would mean anything' }
    foreach ($tag in $tagged) {
        $lineNos = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "# check:$tag(\s|$)") { $i + 1 } })
        $ifs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $lineNos -contains $n.Extent.StartLineNumber }, $true))
        if ($ifs.Count -ne $lineNos.Count) { throw "check:$tag is tagged on $($lineNos.Count) lines but $($ifs.Count) if-statements start there" }
        $mutated = $text
        foreach ($c in @($ifs | ForEach-Object { $_.Clauses[0].Item1.Extent } | Sort-Object StartOffset -Descending)) {
            $mutated = $mutated.Substring(0, $c.StartOffset) + '$false' + $mutated.Substring($c.EndOffset)
        }
        $r = Invoke-Child $tag (New-Copy (Join-Path $work $tag) $mutated)
        $verdict = $(if ($r.Tests -eq 0) { 'NO-TESTS' } elseif ($r.Failed -gt 0) { 'KILLED' } else { 'SURVIVED' })
        $rows.Add([pscustomobject]@{ Check = $tag; Lines = ($lineNos -join ','); Tests = $r.Tests; Failed = $r.Failed; Verdict = $verdict })
    }
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
$rows | Format-Table -AutoSize | Out-String -Width 200
$bad = @($rows | Where-Object { $_.Verdict -ne 'KILLED' })
"MUTATIONS host=$($PSVersionTable.PSVersion) checks=$($rows.Count) killed=$($rows.Count - $bad.Count) not_killed=$($bad.Count)"
if ($bad.Count) { exit 1 }
exit 0
