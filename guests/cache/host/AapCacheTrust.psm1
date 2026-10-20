# Cache trust class of a job (cache-qualification.md rule 6), for the host (P12/P16). Windows PowerShell 5.1 and 7.
# Input is GitHub's record of the job GitHub assigned to the runner, never anything the guest reports. INTEGRATION.md
# names the API calls that produce it. Output: 'trusted', 'untrusted', or $null when the record is incomplete, in which
# case the job gets no shared cache root.

Set-StrictMode -Version 2.0

function Get-AapCacheTrustClass {
    <# Run: the workflow run of the assigned job (GET /repos/{owner}/{repo}/actions/runs/{run_id}): event, head_branch,
       repository.id, head_repository.id. DefaultBranch: GET /repos/{owner}/{repo} .default_branch. TagNamedLikeBranch:
       whether a tag with the same name as head_branch exists; for a tag push the run's head_branch is the tag name, so
       a tag called like the default branch would otherwise pass. $null (not checked) never yields 'trusted'. #>
    param($Run, [string]$DefaultBranch, [Nullable[bool]]$TagNamedLikeBranch)
    if ($null -eq $Run -or [string]::IsNullOrEmpty($DefaultBranch)) { return $null }
    $ev = [string]$Run.event
    $branch = [string]$Run.head_branch
    $repoId = $(if ($Run.repository) { [string]$Run.repository.id } else { '' })
    $headId = $(if ($Run.head_repository) { [string]$Run.head_repository.id } else { '' })
    if (-not $ev) { return $null }
    if (@('push', 'schedule', 'workflow_dispatch') -cnotcontains $ev) { return 'untrusted' }  # SAFETY:TRUST-EVENT
    if ($branch -cne $DefaultBranch) { return 'untrusted' }  # SAFETY:TRUST-BRANCH
    if (-not $repoId -or -not $headId) { return $null }
    if ($headId -ne $repoId) { return 'untrusted' }  # SAFETY:TRUST-HEAD-REPO
    if ($null -eq $TagNamedLikeBranch) { return $null }  # SAFETY:TRUST-TAG-UNKNOWN
    if ($TagNamedLikeBranch) { return 'untrusted' }
    return 'trusted'
}

Export-ModuleMember -Function Get-AapCacheTrustClass
