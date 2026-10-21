# Cache trust class of a job (cache-qualification.md rule 6 as amended: workflow_dispatch is not trusted, and only a run
# of the default branch's current head is), for the host
# (P12/P16). Windows PowerShell 5.1 and 7. Input is GitHub's record of the job GitHub assigned to the runner, never
# anything the guest reports; INTEGRATION.md names the API calls and the token that produce it. Anything incomplete,
# inconsistent or ambiguous yields $null, and a job with no class gets no shared cache root. Only 'trusted' ever gets one.

Set-StrictMode -Version 2.0

function Get-AapCacheProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Select-AapCacheJob {
    <# Jobs: the in-progress jobs listed for the runner group's repositories (GET .../actions/runs/{run_id}/jobs).
       RunnerId: the runner id the broker registered for this VM (its ledger); RunnerGroupId: the pool's runner group.
       Returns the one job GitHub assigned to that runner, or $null when none or several match. #>
    param($Jobs, [long]$RunnerId, [long]$RunnerGroupId)
    if ($RunnerId -le 0 -or $RunnerGroupId -le 0) { return $null }
    $m = @(@($Jobs) | Where-Object { [string](Get-AapCacheProp $_ 'runner_id') -eq [string]$RunnerId -and [string](Get-AapCacheProp $_ 'runner_group_id') -eq [string]$RunnerGroupId })
    if ($m.Count -ne 1) { return $null }  # SAFETY:TRUST-JOB-MATCH
    return $m[0]
}

function Get-AapCacheTrustClass {
    <# Run: the workflow run of the selected job (GET /repos/{owner}/{repo}/actions/runs/{job.run_id}): event,
       head_branch, head_sha, repository.id, head_repository.id. Repository: GET /repos/{owner}/{repo} (id, full_name,
       default_branch). Compare: the body of GET /repos/{owner}/{repo}/compare/{default_branch}...{head_sha} made at
       bind time when it answered 200 (status, base_commit.sha), $null when it failed or was not made.
       Nothing in a run says whether head_branch names a branch or a tag (a tag push reports the tag's name), so a run is
       trusted only when its head_sha IS the default branch's head when the class is bound: status identical, and the
       base commit is the run's head. A tag or a re-run at any older commit is then untrusted; a tag at the current head
       runs exactly that head. Returns @{ trust_class; repository_id; repository } or $null. #>
    param($Run, $Repository, $Compare)
    $repoId = [string](Get-AapCacheProp $Repository 'id')
    $name = [string](Get-AapCacheProp $Repository 'full_name')
    $default = [string](Get-AapCacheProp $Repository 'default_branch')
    $ev = [string](Get-AapCacheProp $Run 'event')
    $branch = [string](Get-AapCacheProp $Run 'head_branch')
    $sha = [string](Get-AapCacheProp $Run 'head_sha')
    $runRepo = [string](Get-AapCacheProp (Get-AapCacheProp $Run 'repository') 'id')
    $headRepo = [string](Get-AapCacheProp (Get-AapCacheProp $Run 'head_repository') 'id')
    $status = [string](Get-AapCacheProp $Compare 'status')
    $base = [string](Get-AapCacheProp (Get-AapCacheProp $Compare 'base_commit') 'sha')
    if (-not $repoId -or -not $name -or -not $default -or -not $ev -or -not $runRepo) { return $null }
    if ($runRepo -ne $repoId) { return $null }  # SAFETY:TRUST-SAME-REPO (the run belongs to another repository)
    $class = 'trusted'
    if (@('push', 'schedule') -cnotcontains $ev) { $class = 'untrusted' }  # SAFETY:TRUST-EVENT
    elseif ($branch -cne $default) { $class = 'untrusted' }  # SAFETY:TRUST-BRANCH
    elseif (-not $headRepo) { return $null }
    elseif ($headRepo -ne $repoId) { $class = 'untrusted' }  # SAFETY:TRUST-HEAD-REPO
    elseif (-not $status) { return $null }  # SAFETY:TRUST-HEAD-UNKNOWN (the compare call failed or was not made)
    elseif ($status -cne 'identical') { $class = 'untrusted' }  # SAFETY:TRUST-HEAD-CURRENT (behind: an older commit)
    elseif (-not $sha -or $base -ne $sha) { return $null }  # SAFETY:TRUST-HEAD-MATCH (an answer about another commit)
    [pscustomobject]@{ trust_class = $class; repository_id = [long]$repoId; repository = $name }
}

Export-ModuleMember -Function Select-AapCacheJob, Get-AapCacheTrustClass
