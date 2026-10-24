# Real host writer for the cross-language conformance run: pass Output to agent_test.sh as AAP_SEED_USER_DATA.
# Pure seed rendering only: no provider, VM, ISO, key pair, state roots or live system call.
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../../supervisor/backends/linux/AapLinBackend.psm1') -Force
$prefix = '192' + '.168.241.'
$name = 'aap-l-1-7-1a2b3c4d'
$network = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b'; vm_name = $name; profile = 'linux'
    subnet = ($prefix + '0/24'); gateway = ($prefix + '1'); address = ($prefix + '2'); resolvers = @(('1.1.' + '1.1'), ('8.8.' + '8.8')); endpoints = @() }
$seed = New-AapLinSeed -VmName $name -InstanceId aap-x -PublicKey ('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI' + ('A' * 43)) -Network $network -ReservationId r-1a2b3c4d000000b1 -LeaseGeneration 7
[IO.File]::WriteAllText($Output, [string]$seed['user-data'], (New-Object Text.UTF8Encoding($false)))
