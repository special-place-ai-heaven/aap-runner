# Shared strict fake of the P10.0 host network module (parity/contracts/host-network-module.md) for the Pester suites of
# its consumers: the image builders (P06, P07) and the VM backends (P10, P11). Windows PowerShell 5.1 and PowerShell 7.
# New-AapFakeHostNetwork returns the module's interface (Attach, Detach, Verify) with the contract's semantics; the
# consumer's own provider fake reports the VM's adapter through Get-AapFakeHostNetworkAdapter, as Hyper-V would. Verify's
# adapter checks are the shared check (supervisor/network/AapHostNetworkCheck.psm1), as the module's are. State lives only
# under -Root, so a child process killed mid-step leaves the world its parent then recovers from:
#   records\<vm id>.json  the module's journal (host_network_record), written before anything is attached
#   knobs.json            tampers (changes to the simulated host, seen by Verify and the read-back alike) and faults
# The simulated adapter is derived from an attached record, never stored. Nothing here calls Hyper-V or the network.
# Lines tagged '# check:<name>' are the checks Invoke-AapHostNetworkMutations.ps1 disables one at a time.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\supervisor\network\AapHostNetworkCheck.psm1')

# The fake host (contract, Shared fake): the four switches of the per-profile candidate, each with its gateway at .1 and no
# DHCP or DNS service; guests get static addresses and two public resolvers (documentation addresses), and no endpoint.
$script:Net = @{
    'aap-guests-win' = @{ Subnet = '172.31.250.0/24'; Gateway = '172.31.250.1' }
    'aap-guests-linux' = @{ Subnet = '172.31.251.0/24'; Gateway = '172.31.251.1' }
    'aap-build-win' = @{ Subnet = '172.31.252.0/24'; Gateway = '172.31.252.1' }
    'aap-build-linux' = @{ Subnet = '172.31.253.0/24'; Gateway = '172.31.253.1' }
}
$script:Resolvers = @('192.0.2.53', '198.51.100.53')
$script:HostAddresses = @('172.31.250.1', '172.31.251.1', '172.31.252.1', '172.31.253.1', '172.29.16.1', '2001:db8:5::1')   # the vEthernet adapters'
$script:LanPrefixes = @('2001:db8:1::/64')
$script:PublicHost = '203.0.113.7'   # what the public-host tamper gives the host
$script:DenyWeight = 10
$script:AllowWeight = 100
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:TamperNames = @('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on',
    'port-mirroring', 'vlan-trunk', 'foreign-peer', 'drop-fixed-deny', 'drop-inbound-deny', 'scoped-deny', 'drop-host-deny', 'extra-allow', 'public-host')
$script:FailNames = @('Attach', 'AttachAfterIntent', 'Detach', 'Verify')
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function New-AapFakeHostNetwork {
    <# The module's interface on the fake host. -VmExists answers whether Hyper-V has the VM id it is given: the consumer's
       own fake world owns the VMs. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$VmExists)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'records'))
    # The closures call an exported function: a closure made here no longer sees this module's private ones.
    @{
        Attach = { param($a) Invoke-AapFakeHostNetwork -Root $Root -VmExists $VmExists -Op Attach -Request $a }.GetNewClosure()
        Detach = { param($a) Invoke-AapFakeHostNetwork -Root $Root -VmExists $VmExists -Op Detach -Request $a }.GetNewClosure()
        Verify = { param($a) Invoke-AapFakeHostNetwork -Root $Root -VmExists $VmExists -Op Verify -Request $a }.GetNewClosure()
    }
}

function Invoke-AapFakeHostNetwork {
    # One call of the interface; exported only for New-AapFakeHostNetwork's closures.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$VmExists,
        [Parameter(Mandatory)][ValidateSet('Attach', 'Detach', 'Verify')][string]$Op, $Request)
    $q = ConvertTo-AapFakeNetRequest $Request
    $fail = @((Read-AapFakeNetKnobs $Root).fail)
    if ($fail -ccontains $Op) { throw "AAP_NetworkUntrusted: fake: $Op failed" }
    $exists = [bool](& $VmExists $q.VmId)
    switch ($Op) {
        'Attach' { Add-AapFakeNetAttachment $Root $q $exists ($fail -ccontains 'AttachAfterIntent') }
        'Detach' { Remove-AapFakeNetAttachment $Root $q $exists }
        'Verify' { Get-AapFakeNetProblem $Root $q $exists }
    }
}

function Get-AapFakeHostNetworkAdapter {
    <# What Hyper-V would report for the VM's adapters, in the contract's provider shape (Consumer obligations, read-back):
       nothing before Attach finishes or after Detach, one adapter while attached, tampers applied. Peers are the other
       attached records whose VMs belong on the same switch. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$VmId)
    $rec = Read-AapFakeNetRecord $Root $VmId
    if ($null -eq $rec -or $rec.state -cne 'attached') { return }
    $d = $rec.declaration
    $sw = Get-AapHostNetworkSwitchName ([string]$d.vm_name)
    $tamper = @((Read-AapFakeNetKnobs $Root).tamper)
    $count = $(if ($tamper -ccontains 'no-adapter') { 0 } elseif ($tamper -ccontains 'second-adapter') { 2 } else { 1 })
    for ($i = 0; $i -lt $count; $i++) {
        # Denies only: the fake declares no endpoint, so it writes no allow.
        $acls = @(foreach ($dir in 'Inbound', 'Outbound') {
                foreach ($r in @(@(Get-AapHostNetworkFixedDeny) + @(Get-AapFakeNetHostTarget @()))) { New-AapFakeNetRule 'Deny' $dir $r $script:DenyWeight }
            })
        $peers = @(Get-AapFakeNetNeighbour $Root $VmId $sw | Where-Object { $_.state -ceq 'attached' } | ForEach-Object { [string]$_.declaration.vm_name })
        $n = @{ SwitchName = $sw; SwitchType = 'Internal'; DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; PortMirroringMode = 'None'; VlanMode = 'Untagged'
            Peers = $peers; Acls = $acls
        }
        switch -CaseSensitive ($tamper) {
            'external-switch' { $n.SwitchType = 'External' }
            'other-switch' { $n.SwitchName = $(if ($d.profile -ceq 'windows') { 'aap-guests-linux' } else { 'aap-guests-win' }) }
            'dhcp-guard-off' { $n.DhcpGuard = 'Off' }
            'router-guard-off' { $n.RouterGuard = 'Off' }
            'mac-spoofing-on' { $n.MacAddressSpoofing = 'On' }
            'port-mirroring' { $n.PortMirroringMode = 'Destination' }
            'vlan-trunk' { $n.VlanMode = 'Trunk' }
            'foreign-peer' { $n.Peers = @($n.Peers) + @('aap-wbuild-0badc0de') }
            'drop-fixed-deny' { $n.Acls = @($n.Acls | Where-Object { -not ($_.Direction -ceq 'Outbound' -and $_.RemoteAddress -ceq '10.0.0.0/8') }) }
            'drop-inbound-deny' { $n.Acls = @($n.Acls | Where-Object { -not ($_.Direction -ceq 'Inbound' -and $_.RemoteAddress -ceq '10.0.0.0/8') }) }
            'scoped-deny' { foreach ($r in $n.Acls) { if ($r.Direction -ceq 'Inbound' -and $r.RemoteAddress -ceq '192.168.0.0/16') { $r.Protocol = 'TCP'; $r.LocalPort = '1' } } }
            'drop-host-deny' { $n.Acls = @($n.Acls | Where-Object { $_.RemoteAddress -cne $script:LanPrefixes[0] }) }
            'extra-allow' { $n.Acls = @($n.Acls) + @(New-AapFakeNetRule 'Allow' 'Outbound' ([string]$d.gateway) $script:AllowWeight) }
        }
        $n
    }
}

function Set-AapFakeHostNetworkKnob {
    <# Tampers change the simulated host, so Verify and the read-back both see them; faults make an op throw
       (AttachAfterIntent: Attach stops after its intent record, as a crash would). Each call replaces both lists. #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Tamper = @(), [string[]]$Fail = @())
    $unknown = @(@($Tamper | Where-Object { $script:TamperNames -cnotcontains $_ }) + @($Fail | Where-Object { $script:FailNames -cnotcontains $_ }))
    if ($unknown.Count) { throw "fake: unknown tamper or fault: $($unknown -join ', ')" }   # check:knob-names
    [IO.File]::WriteAllText((Join-Path $Root 'knobs.json'), (@{ tamper = @($Tamper); fail = @($Fail) } | ConvertTo-Json), $script:Utf8)
}

function Get-AapFakeHostNetworkRecord {
    # The journal records under -Root (with -VmId, that VM's only), as the module keeps them.
    param([Parameter(Mandatory)][string]$Root, [string]$VmId)
    $ids = $(if ($VmId) { @($VmId) } else { @(Get-ChildItem -LiteralPath (Join-Path $Root 'records') -Filter '*.json' -File | ForEach-Object { $_.BaseName }) })
    foreach ($id in $ids) { $r = Read-AapFakeNetRecord $Root $id; if ($null -ne $r) { $r } }
}

# ---- the three operations -----------------------------------------------------------------------------------------------

function ConvertTo-AapFakeNetRequest($Request) {
    $ok = $Request -is [Collections.IDictionary] -and $Request.Count -eq 3 -and $Request.Contains('VmId') -and $Request.Contains('VmName') -and $Request.Contains('Profile')
    if ($ok) {
        $id = [string]$Request['VmId']; $name = [string]$Request['VmName']; $prof = [string]$Request['Profile']
        $ok = $id -cmatch $script:GuidRe -and (Get-AapHostNetworkSwitchName $name) -and @('windows', 'linux') -ccontains $prof -and $name[4] -ceq $prof[0]
    }
    if (-not $ok) { throw 'AAP_NetworkUntrusted: the request is not exactly @{ VmId; VmName; Profile } for an attachable VM' }   # check:request
    @{ VmId = $id; VmName = $name; Profile = $prof }
}

function Add-AapFakeNetAttachment([string]$Root, $q, [bool]$Exists, [bool]$StopAfterIntent) {
    if (-not $Exists) { throw "AAP_NetworkUntrusted: VM $($q.VmId) does not exist" }   # check:attach-vm
    $rec = Read-AapFakeNetRecord $Root $q.VmId
    if ($null -ne $rec -and ($rec.declaration.vm_name -cne $q.VmName -or $rec.declaration.profile -cne $q.Profile)) {   # check:attach-same-vm
        throw "AAP_NetworkUntrusted: VM $($q.VmId) is recorded as $($rec.declaration.vm_name) ($($rec.declaration.profile))"
    }
    if ($null -eq $rec) {
        $sw = Get-AapHostNetworkSwitchName $q.VmName
        $others = @(Get-AapFakeNetNeighbour $Root $q.VmId $sw)
        # A build VM shares its switch with no VM (contract, Switches): refused while another record names that switch.
        if ($sw -clike 'aap-build-*' -and $others.Count) { throw "AAP_NetworkUntrusted: $sw already carries $(@($others | ForEach-Object { $_.declaration.vm_name }) -join ', ')" }   # check:attach-peers
        # The VM's static address: the lowest host address of the subnet that is not the gateway and no other record's.
        $n = $script:Net[$sw]
        $held = @(@($others | ForEach-Object { [string]$_.declaration.address }) + $n.Gateway)
        $base = $n.Subnet.Substring(0, $n.Subnet.LastIndexOf('.'))
        $address = @(1..254 | ForEach-Object { "$base.$_" } | Where-Object { $held -notcontains $_ })[0]
        # Intent before act: the record names the declaration and what Attach creates before anything changes.
        $decl = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = $q.VmId; vm_name = $q.VmName; profile = $q.Profile; subnet = $n.Subnet
            gateway = $n.Gateway; address = $address; resolvers = $script:Resolvers; endpoints = @()
        }
        Write-AapFakeNetRecord $Root ([ordered]@{ schema = 1; kind = 'host_network_record'; state = 'attaching'; declaration = $decl; created = @([ordered]@{ kind = 'adapter'; name = 'aap-guest' }) })
        $rec = Read-AapFakeNetRecord $Root $q.VmId
    }
    if ($StopAfterIntent) { throw 'AAP_NetworkUntrusted: fake: Attach stopped after its intent record' }
    # From here the adapter, its guards and its port ACLs exist: the simulated host derives them from the attached record.
    if ($rec.state -cne 'attached') { $rec.state = 'attached'; Write-AapFakeNetRecord $Root $rec }
    $rec.declaration
}

function Remove-AapFakeNetAttachment([string]$Root, $q, [bool]$Exists) {
    if ($Exists) { throw "AAP_NetworkUntrusted: VM $($q.VmId) still exists; remove the VM before Detach" }   # check:detach-order
    $rec = Read-AapFakeNetRecord $Root $q.VmId
    if ($null -eq $rec) { return }   # never attached, or detached already
    if ($rec.declaration.vm_name -cne $q.VmName -or $rec.declaration.profile -cne $q.Profile) {   # check:detach-same-vm
        throw "AAP_NetworkUntrusted: VM $($q.VmId) is recorded as $($rec.declaration.vm_name) ($($rec.declaration.profile))"
    }
    # The adapter and its port ACLs went with the VM and the per-profile switch is not the VM's: only the record is left,
    # and with it goes the VM's address.
    $path = Get-AapFakeNetRecordPath $Root $q.VmId
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }   # check:detach-removes
}

# Verify: check 1 from the record, checks 2 to 7 the shared check on the simulated adapter with the fake host's targets;
# never from a knob directly.
function Get-AapFakeNetProblem([string]$Root, $q, [bool]$Exists) {
    $id = $q.VmId
    if (-not $Exists) { return "VM $id does not exist" }   # check:verify-vm
    $rec = Read-AapFakeNetRecord $Root $id
    if ($null -eq $rec -or $rec.state -cne 'attached') { return "VM $id is not attached" }   # check:verify-record
    $d = $rec.declaration
    if ($d.vm_name -cne $q.VmName -or $d.profile -cne $q.Profile) { return "VM $id is recorded as $($d.vm_name) ($($d.profile))" }   # check:verify-record
    $targets = @(Get-AapFakeNetHostTarget @((Read-AapFakeNetKnobs $Root).tamper))
    Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @(Get-AapFakeHostNetworkAdapter -Root $Root -VmId $id) -HostDeny $targets
}

# ---- records, knobs and the fake host -----------------------------------------------------------------------------------

function Get-AapFakeNetRecordPath([string]$Root, [string]$VmId) { Join-Path $Root "records\$VmId.json" }

function Read-AapFakeNetRecord([string]$Root, [string]$VmId) {
    $path = Get-AapFakeNetRecordPath $Root $VmId
    if (-not [IO.File]::Exists($path)) { return $null }
    $ok = $false
    try {
        $rec = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $ok = $rec.kind -ceq 'host_network_record' -and @('attaching', 'attached') -ccontains $rec.state -and $rec.declaration.vm_id -ceq $VmId
    } catch { $ok = $false }
    if (-not $ok) { throw "AAP_NetworkUntrusted: the record of VM $VmId is unreadable; it stays for an owner" }   # check:record-readable
    $rec
}

function Write-AapFakeNetRecord([string]$Root, $Record) {
    [IO.File]::WriteAllText((Get-AapFakeNetRecordPath $Root ([string]$Record.declaration.vm_id)), ($Record | ConvertTo-Json -Depth 6), $script:Utf8)
}

# The other readable records whose VMs belong on $Switch (an unreadable record is its own VM's problem).
function Get-AapFakeNetNeighbour([string]$Root, [string]$VmId, [string]$Switch) {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root 'records') -Filter '*.json' -File)) {
        if ($f.BaseName -ceq $VmId) { continue }
        $r = $null
        try { $r = Read-AapFakeNetRecord $Root $f.BaseName } catch { continue }
        if ((Get-AapHostNetworkSwitchName ([string]$r.declaration.vm_name)) -ceq $Switch) { $r }
    }
}

function Read-AapFakeNetKnobs([string]$Root) {
    $path = Join-Path $Root 'knobs.json'
    if (-not [IO.File]::Exists($path)) { return @{ tamper = @(); fail = @() } }
    $k = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    @{ tamper = @($k.tamper | Where-Object { $_ }); fail = @($k.fail | Where-Object { $_ }) }
}

function New-AapFakeNetRule([string]$Action, [string]$Direction, [string]$Remote, [int]$Weight, [string]$Protocol = 'ANY', [string]$RemotePort = 'ANY') {
    @{ Action = $Action; Direction = $Direction; RemoteAddress = $Remote; LocalAddress = 'ANY'; Protocol = $Protocol; RemotePort = $RemotePort; LocalPort = 'ANY'; Weight = $Weight }
}

# What the host-specific denies must cover (contract, Verify check 5): the host's addresses and its LAN IPv6 prefixes. The
# fake writes exactly these as its host-specific denies; the public-host tamper adds an address it cannot cover.
function Get-AapFakeNetHostTarget([string[]]$Tamper) {
    $addresses = @(@($script:HostAddresses) + @(if ($Tamper -ccontains 'public-host') { $script:PublicHost }))
    @($addresses | ForEach-Object { if ($_.Contains(':')) { "$_/128" } else { "$_/32" } }) + $script:LanPrefixes
}

Export-ModuleMember -Function New-AapFakeHostNetwork, Invoke-AapFakeHostNetwork, Get-AapFakeHostNetworkAdapter, Set-AapFakeHostNetworkKnob,
    Get-AapFakeHostNetworkRecord
