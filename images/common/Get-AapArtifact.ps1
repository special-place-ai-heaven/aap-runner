# Fetch or verify the artifacts in a manifest into a staging directory. Downloads data only; executes nothing.
#   Online : pwsh -File Get-AapArtifact.ps1 -Staging D:\stage [-Name zccache-sha256sums] [-RecordFirstFetch]
#   Offline: pwsh -File Get-AapArtifact.ps1 -Staging D:\stage -Offline        (no network; verifies pre-fetched files)
# Exit 0 only when every selected entry is accepted. Unreproducible inputs are always listed as blockers.
# A -Name that is not an entry of the manifest is an error. An entry with no upstream hash (first-fetch) needs
# -RecordFirstFetch once; after that it must match <file>.first-fetch.json, online or offline.
param(
    [string]$Manifest = (Join-Path $PSScriptRoot 'artifacts.manifest.json'),
    [Parameter(Mandatory)][string]$Staging,
    [string[]]$Name,
    [switch]$Offline,
    [switch]$RecordFirstFetch
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AapArtifact.psm1') -Force
$m = Read-AapManifest -Path $Manifest
$r = Invoke-AapManifest -Manifest $m -StagingRoot $Staging -Name $Name -Offline:$Offline -RecordFirstFetch:$RecordFirstFetch
foreach ($x in $r.Results) { '{0,-9} {1}{2}' -f $x.Status, $x.Name, $(if ($x.Message) { "  $($x.Message)" } else { '' }) }
foreach ($b in $r.Blockers) { 'BLOCKER   {0}: {1}' -f $b.id, $b.owner_action }
if ($r.Complete) { exit 0 } else { exit 1 }
