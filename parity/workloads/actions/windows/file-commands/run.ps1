# actions/windows/file-commands: checks the marker the composite action in this folder wrote earlier in the same job
# (same run id and attempt), so GITHUB_ENV/PATH/OUTPUT/STEP_SUMMARY and working-directory behaviour lands in the results.
# Sabotage missing-marker looks for a marker that was never written.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\..\..\windows\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    if ($env:GITHUB_ACTIONS -ne 'true') { throw 'not inside a GitHub Actions job (GITHUB_ACTIONS is not true)' }
    $name = if ($Sabotage -eq 'missing-marker') { 'aap-parity-file-commands.missing.json' } else { 'aap-parity-file-commands.json' }
    $marker = Join-Path $env:RUNNER_TEMP $name
    if (-not (Test-Path -LiteralPath $marker)) {
        throw 'file-commands marker not found: run uses: ./parity/workloads/actions/windows/file-commands earlier in this job'
    }
    $m = Get-Content -Raw -LiteralPath $marker | ConvertFrom-Json
    Add-Fact 'marker.run_id' $m.run_id $env:GITHUB_RUN_ID
    Add-Fact 'marker.run_attempt' $m.run_attempt $env:GITHUB_RUN_ATTEMPT
    $report = @()
    foreach ($p in $m.checks.PSObject.Properties) {
        Add-Fact "check.$($p.Name)" $p.Value $true
        $report += "$($p.Name)=$($p.Value)"
    }
    Write-Report $report
}
