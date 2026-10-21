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
       default_branch). BranchRef: the body of GET /repos/{owner}/{repo}/git/ref/heads/{default_branch} (the branch-only,
       exact-match endpoint) made at bind time when it answered 200 (ref, url, object.type, object.sha), $null when it
       failed or was not made. EnabledRepositoryIds: the repositories the owner enabled for a shared root, recorded
       host-side (INTEGRATION.md decision 4); any other repository gets no class.
       Nothing in a run says whether head_branch names a branch or a tag (a tag push reports the tag's name), so a run is
       trusted only when its head_sha IS the default branch's head when the class is bound: the answer is that branch's
       ref of that repository, pointing at a commit, and its sha is the run's head. A tag or a re-run at any older commit
       is then untrusted; a tag at the current head runs exactly that head. Returns @{ trust_class; repository_id;
       repository } or $null. #>
    param($Run, $Repository, $BranchRef, $EnabledRepositoryIds)
    $id = [long]0
    if (-not [long]::TryParse([string](Get-AapCacheProp $Repository 'id'), [ref]$id) -or $id -le 0) { return $null }  # SAFETY:TRUST-REPO-ID
    $repoId = [string]$id
    $name = [string](Get-AapCacheProp $Repository 'full_name')
    $default = [string](Get-AapCacheProp $Repository 'default_branch')
    $ev = [string](Get-AapCacheProp $Run 'event')
    $branch = [string](Get-AapCacheProp $Run 'head_branch')
    $sha = [string](Get-AapCacheProp $Run 'head_sha')
    $runRepo = [string](Get-AapCacheProp (Get-AapCacheProp $Run 'repository') 'id')
    $headRepo = [string](Get-AapCacheProp (Get-AapCacheProp $Run 'head_repository') 'id')
    $refName = [string](Get-AapCacheProp $BranchRef 'ref')
    $refUrl = [string](Get-AapCacheProp $BranchRef 'url')
    $refType = [string](Get-AapCacheProp (Get-AapCacheProp $BranchRef 'object') 'type')
    $refSha = [string](Get-AapCacheProp (Get-AapCacheProp $BranchRef 'object') 'sha')
    if (-not $name -or -not $default -or -not $ev -or -not $runRepo) { return $null }
    if ($runRepo -ne $repoId) { return $null }  # SAFETY:TRUST-SAME-REPO (the run belongs to another repository)
    if (@($EnabledRepositoryIds) -notcontains $id) { return $null }  # SAFETY:TRUST-ACTIVATION (not enabled by the owner)
    $class = 'trusted'
    if (@('push', 'schedule') -cnotcontains $ev) { $class = 'untrusted' }  # SAFETY:TRUST-EVENT
    elseif ($branch -cne $default) { $class = 'untrusted' }  # SAFETY:TRUST-BRANCH
    elseif (-not $headRepo) { return $null }
    elseif ($headRepo -ne $repoId) { $class = 'untrusted' }  # SAFETY:TRUST-HEAD-REPO
    elseif (-not $refSha -or -not $sha) { return $null }  # SAFETY:TRUST-HEAD-UNKNOWN (the ref call failed or was not made)
    elseif ($refName -cne "refs/heads/$default") { return $null }  # SAFETY:TRUST-HEAD-REF (an answer about another ref)
    elseif ($refType -cne 'commit') { return $null }  # SAFETY:TRUST-HEAD-TYPE
    elseif ($refUrl -cne "https://api.github.com/repos/$name/git/refs/heads/$default") { return $null }  # SAFETY:TRUST-HEAD-URL (about another repository)
    elseif ($refSha -cne $sha) { $class = 'untrusted' }  # SAFETY:TRUST-HEAD-CURRENT (an older or another commit)
    [pscustomobject]@{ trust_class = $class; repository_id = $id; repository = $name }
}

Export-ModuleMember -Function Select-AapCacheJob, Get-AapCacheTrustClass
