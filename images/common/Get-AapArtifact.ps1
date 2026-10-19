# Fetch or verify the artifacts in a manifest into a staging directory. Downloads data only; executes nothing.
#   Online : pwsh -File Get-AapArtifact.ps1 -Staging D:\aap-runner\images\staging [-Name zccache-sha256sums] [-RecordFirstFetch]
#   Offline: pwsh -File Get-AapArtifact.ps1 -Staging D:\aap-runner\images\staging -Offline   (no network; verifies pre-fetched files)
# The staging folder must be locked: a plain folder on a fixed local disk, owned by SYSTEM, Administrators or
# TrustedInstaller that nobody else can write to or delete, below ancestors that nobody else can delete or re-permission.
# The name and version folders under it, new or not, and the files it reads or publishes there must pass the same owner
# and ACL rule (README.md says what happens to one that does not). Until the installer (P19)
# creates and locks D:\aap-runner, and D:\ itself is tightened, this check fails on the lab host: see README.md.
# -TrustedSid and -SkipAncestorCheck relax that check for developer boxes and tests only; the provenance records it.
#
# Exit codes: 0 every selected entry is accepted and verified against a hash source;
#             1 an entry was rejected, or the run was refused (bad manifest, unknown -Name, untrusted staging folder);
#             3 nothing was rejected, but an entry with no published hash (first-fetch) was accepted unverified.
# Unreproducible inputs are always listed as blockers. A -Name that is not an entry of the manifest is an error.
# An entry with no upstream hash (first-fetch) is downloaded on every online run, needs -RecordFirstFetch once, and
# after that must match <file>.first-fetch.json, online or offline.
param(
    [string]$Manifest = (Join-Path $PSScriptRoot 'artifacts.manifest.json'),
    [Parameter(Mandatory)][string]$Staging,
    [string[]]$Name,
    [switch]$Offline,
    [switch]$RecordFirstFetch,
    [string[]]$TrustedSid = @(),
    [switch]$SkipAncestorCheck
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AapArtifact.psm1') -Force
$m = Read-AapManifest -Path $Manifest
if (@($TrustedSid | Where-Object { $_ }).Count -or $SkipAncestorCheck) { 'WARNING   staging trust checks relaxed (developer and test use only)' }
$r = Invoke-AapManifest -Manifest $m -StagingRoot $Staging -Name $Name -Offline:$Offline -RecordFirstFetch:$RecordFirstFetch -TrustedSid $TrustedSid -SkipAncestorCheck:$SkipAncestorCheck
foreach ($x in $r.Results) { '{0,-9} {1}{2}{3}' -f $x.Status, $x.Name, $(if ($x.Status -eq 'accepted' -and -not $x.Verified) { '  (unverified: no published hash)' } else { '' }), $(if ($x.Message) { "  $($x.Message)" } else { '' }) }
foreach ($b in $r.Blockers) { 'BLOCKER   {0}: {1}' -f $b.id, $b.owner_action }
if ($r.Rejected.Count) { exit 1 }
if ($r.Unverified.Count) { exit 3 }
exit 0
