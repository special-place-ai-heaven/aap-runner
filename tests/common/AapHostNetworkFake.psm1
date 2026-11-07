# Shared strict fake of the P10.0 host network module (parity/contracts/host-network-module.md) for the Pester suites of
# its consumers: the image builders (P06, P07) and the VM backends (P10, P11). Windows PowerShell 5.1 and PowerShell 7.
# New-AapFakeHostNetwork returns the module's interface (Attach, Detach, Verify) with the contract's semantics; the
# consumer's own provider fake reports the VM's adapter through Get-AapFakeHostNetworkAdapter, as Hyper-V would. Verify's
# adapter checks are the shared check (supervisor/network/AapHostNetworkCheck.psm1), as the module's are. State lives only
# under -Root, so a child process killed mid-step leaves the world its parent then recovers from:
#   records\<vm id>.json  the module's journal (host_network_record), written before anything is attached
#   released.json         addresses Detach freed, least recently used first; written like a record; unreadable, it stops
#                         Attach and Detach until Repair-AapFakeHostNetworkReleased rebuilds it
#   lock                  the journal lock, held exclusively for every record write and every read of all records
#   lock-<vm id>          the VM's lifecycle lock: an Attach or a Detach of that VM takes it before Hyper-V is asked about the VM
#                         and holds it until the call returns, so the two never interleave (contract, Journal); the journal lock
#                         is taken inside it, never the other way round, and Verify takes the journal lock alone
#   host\<vm id>          the simulated host: the VM has the module's adapter (its guards and ACLs follow from the record)
#   knobs.json            tampers (changes to the simulated host, seen by Verify and the read-back alike), faults and pauses
#   barrier\              a test's scheduler: with a pause set the op writes <pause>.reached and waits for <pause>.go
#
# The record also holds the guest's static MAC (the module's range, lowest free). The host's permanent neighbour entry for
# the guest's address is modelled like the adapter (contract, Attach and Detach), in the host's neighbour table, one file
# per interface and address as the host keys it: Attach first reads the host's entries for the address on every interface
# and throws on any that is not exactly the record's, never overwriting it; its act then adds the entry and reads the table
# back; Detach removes the record's own tuple only and reads the table back; Verify reads the entries and passes them to
# the shared check as -Neighbors, with the management adapter's identity as -HostInterface, never without them:
#   neighbor\<interface index>-<address>.json  one entry as Get-NetNeighbor shows it (IPAddress, LinkLayerAddress, State,
#                         InterfaceAlias, InterfaceIndex); the module's is permanent, carries the declared MAC and sits on
#                         the switch's management adapter; a test plants others (Add-AapFakeHostNetworkNeighbor)
# Verify also passes the MAC of every other adapter on the VM's switch (the other VMs' adapters and the host's own) as
# -PeerMacs, holds no other record to the VM's MAC, and checks the switch's enabled extensions against the baseline P19
# recorded and that no HNS network uses it (check 9). The recovery of an entry no record names, a deleted or unreadable
# record's, is Get-AapFakeHostNetworkOrphan and Remove-AapFakeHostNetworkNeighbor (contract, Journal).
# Nothing here calls Hyper-V or the network.
# Lines tagged '# check:<name>' are the checks Invoke-AapHostNetworkMutations.ps1 disables one at a time.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\supervisor\network\AapHostNetworkCheck.psm1')

# The fake host (contract, Shared fake): the four switches of the per-profile candidate, each with its gateway at .1 and no
# DHCP or DNS service, and the host's management adapter on it (vEthernet (<switch>), by its interface index); guests get
# static addresses and two public resolvers (documentation addresses), and no endpoint.
$script:Net = @{
    'aap-guests-win' = @{ Subnet = '172.31.250.0/24'; Gateway = '172.31.250.1'; InterfaceIndex = 31 }
    'aap-guests-linux' = @{ Subnet = '172.31.251.0/24'; Gateway = '172.31.251.1'; InterfaceIndex = 32 }
    'aap-build-win' = @{ Subnet = '172.31.252.0/24'; Gateway = '172.31.252.1'; InterfaceIndex = 33 }
    'aap-build-linux' = @{ Subnet = '172.31.253.0/24'; Gateway = '172.31.253.1'; InterfaceIndex = 34 }
}
$script:Resolvers = @('192.0.2.53', '198.51.100.53')
$script:HostAddresses = @('172.31.250.1', '172.31.251.1', '172.31.252.1', '172.31.253.1', '172.29.16.1', '2001:db8:5::1')   # the vEthernet adapters'
$script:OnLink = @('172.31.250.0/24', '172.31.251.0/24', '172.31.252.0/24', '172.31.253.0/24', '172.29.16.0/20')   # each vEthernet adapter's IPv4 prefix
$script:LanPrefixes = @('2001:db8:1::/64')
$script:LanAddresses = @('192.168.1.10')   # the host's own address on its LAN card, not a vEthernet adapter
$script:PublicHost = '203.0.113.7'   # what the public-host tamper gives the host
$script:HostAdapterMac = '00-15-5D-0F-A0-01'   # the host's own vEthernet adapter on every switch (Hyper-V's dynamic range, not the module's)
$script:ExtensionBaseline = @('Microsoft Windows Filtering Platform')   # the extensions P19 recorded as enabled on every switch (the set is the lab's, D2)
$script:ExtraExtension = 'Microsoft NDIS Capture'   # what the switch-extension tamper enables on top of the baseline
$script:HnsNetwork = 'nat'   # the HNS network the hns-network tamper puts on the switch
$script:Weight = @{ CatchAll = 1; Pin = 5; Deny = 10 }   # one per rule class (contract, Rules and weights); no endpoint, so no endpoint allow
$script:LockSeconds = 30
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:TamperNames = @('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on',
    'port-mirroring', 'vlan-trunk', 'storm-limit-off', 'legacy-acl', 'foreign-peer', 'adapter-mac', 'neighbor-missing', 'neighbor-mac', 'neighbor-state',
    'neighbor-interface', 'neighbor-unreadable', 'neighbor-add-lost', 'neighbor-stuck', 'peer-mac-clash', 'switch-extension', 'switch-extension-off', 'hns-network',
    'switch-unreadable', 'drop-fixed-deny', 'drop-inbound-deny', 'scoped-deny', 'stateful-rule', 'isolated-rule', 'no-source-pin', 'pin-above-deny', 'extra-allow',
    'public-host', 'host-empty', 'host-no-gateway', 'host-no-lan')
$script:FailNames = @('Attach', 'AttachAfterIntent', 'AttachAfterAct', 'Detach', 'DetachAfterNeighbor', 'DetachAfterReleased', 'Verify')
$script:PauseNames = @('AttachBeforeAct')
$script:BarrierSeconds = 60
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function New-AapFakeHostNetwork {
    <# The module's interface on the fake host. -Vm answers what Hyper-V has for the VM id it is given: $null only when
       Hyper-V definitively has no such VM, else @{ State = 'Off', 'Running', ...; Adapters = <its adapters the module did not
       make> }; it throws when it cannot look, and so does the call. The consumer's own fake world owns the VMs. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Vm)
    foreach ($sub in 'records', 'host', 'neighbor') { [void][IO.Directory]::CreateDirectory((Join-Path $Root $sub)) }
    # The closures call an exported function: a closure made here no longer sees this module's private ones.
    @{
        Attach = { param($a) Invoke-AapFakeHostNetwork -Root $Root -Vm $Vm -Op Attach -Request $a }.GetNewClosure()
        Detach = { param($a) Invoke-AapFakeHostNetwork -Root $Root -Vm $Vm -Op Detach -Request $a }.GetNewClosure()
        Verify = { param($a) Invoke-AapFakeHostNetwork -Root $Root -Vm $Vm -Op Verify -Request $a }.GetNewClosure()
    }
}

function Invoke-AapFakeHostNetwork {
    # One call of the interface; exported only for New-AapFakeHostNetwork's closures.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Vm,
        [Parameter(Mandatory)][ValidateSet('Attach', 'Detach', 'Verify')][string]$Op, $Request)
    $q = ConvertTo-AapFakeNetRequest $Request
    $fail = @((Read-AapFakeNetKnobs $Root).fail)
    if ($fail -ccontains $Op) { throw "AAP_NetworkUntrusted: fake: $Op failed" }
    # Attach and Detach of one VM run one at a time, each whole (contract, Journal): the lifecycle lock is taken before Hyper-V
    # is asked about the VM and held until the call returns, so a Detach never runs between an Attach's checks and its act, and
    # an Attach that starts after a Detach finds the VM gone. The journal lock stays short and is taken inside this one; Verify
    # reads under the journal lock alone.
    $vmLock = $null
    if ($Op -cne 'Verify') { $vmLock = Enter-AapFakeNetLock $Root "lock-$($q.VmId)" }   # check:vm-lifecycle-lock
    try {
        $have = & $Vm $q.VmId
        switch ($Op) {
            'Attach' { Add-AapFakeNetAttachment $Root $q $have $fail }
            'Detach' { Remove-AapFakeNetAttachment $Root $q $have $fail }
            'Verify' { Get-AapFakeNetProblem $Root $q $have $Vm }
        }
    } finally { if ($null -ne $vmLock) { $vmLock.Dispose() } }
}

function Get-AapFakeHostNetworkAdapter {
    <# What Hyper-V would report for the VM's adapters, in the contract's provider shape (Consumer obligations, read-back):
       nothing before Attach's act or after Detach, one adapter from the act on (also while the record still says
       attaching), tampers applied. Peers are the other VMs with the module's adapter on the same switch; a removed VM's
       adapter shows until Detach (fail closed). #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$VmId)
    $lock = Enter-AapFakeNetLock $Root
    try { $rec = Read-AapFakeNetRecord $Root $VmId; $all = @(Get-AapFakeNetRecords $Root) } finally { $lock.Dispose() }
    if ($null -eq $rec -or -not [IO.File]::Exists((Get-AapFakeNetHostPath $Root $VmId))) { return }
    $d = $rec.declaration
    $sw = Get-AapHostNetworkSwitchName ([string]$d.vm_name)
    $tamper = @((Read-AapFakeNetKnobs $Root).tamper)
    $count = $(if ($tamper -ccontains 'no-adapter') { 0 } elseif ($tamper -ccontains 'second-adapter') { 2 } else { 1 })
    for ($i = 0; $i -lt $count; $i++) {
        # The fixed denies both ways and, outbound, the catch-all deny and the source pin; no endpoint, so no other allow.
        $acls = @(foreach ($dir in 'Inbound', 'Outbound') {
                if ($dir -ceq 'Outbound') {
                    New-AapFakeNetRule 'Deny' $dir '0.0.0.0/0' $script:Weight.CatchAll
                    New-AapFakeNetRule 'Allow' $dir '0.0.0.0/0' $script:Weight.Pin -Local "$($d.address)/32"
                }
                foreach ($r in @(Get-AapHostNetworkFixedDeny)) { New-AapFakeNetRule 'Deny' $dir $r $script:Weight.Deny }
            })
        $peers = @($all | Where-Object { $_.declaration.vm_id -cne $VmId -and (Get-AapHostNetworkSwitchName ([string]$_.declaration.vm_name)) -ceq $sw -and
                [IO.File]::Exists((Get-AapFakeNetHostPath $Root ([string]$_.declaration.vm_id))) } | ForEach-Object { [string]$_.declaration.vm_name })
        # The adapter's MAC is the record's (contract, Attach): the tamper changes the simulated adapter, as a host change
        # would, so Verify and a consumer's read-back both see it.
        $n = @{ SwitchName = $sw; SwitchType = 'Internal'; MacAddress = $(if ($tamper -ccontains 'adapter-mac') { '00-15-5D-8A-3B-7C' } else { [string]$d.mac })
            DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; PortMirroringMode = 'None'; VlanMode = 'Untagged'
            StormLimit = '100'; LegacyAcls = 0; Peers = $peers; Acls = $acls
        }
        switch -CaseSensitive ($tamper) {
            'external-switch' { $n.SwitchType = 'External' }
            'other-switch' { $n.SwitchName = $(if ($d.profile -ceq 'windows') { 'aap-guests-linux' } else { 'aap-guests-win' }) }
            'dhcp-guard-off' { $n.DhcpGuard = 'Off' }
            'router-guard-off' { $n.RouterGuard = 'Off' }
            'mac-spoofing-on' { $n.MacAddressSpoofing = 'On' }
            'port-mirroring' { $n.PortMirroringMode = 'Destination' }
            'vlan-trunk' { $n.VlanMode = 'Trunk' }
            'storm-limit-off' { $n.StormLimit = '0' }
            'legacy-acl' { $n.LegacyAcls = 1 }
            'foreign-peer' { $n.Peers = @($n.Peers) + @('aap-wbuild-0badc0de') }
            'drop-fixed-deny' { $n.Acls = @($n.Acls | Where-Object { -not ($_.Direction -ceq 'Outbound' -and $_.RemoteAddress -ceq '10.0.0.0/8') }) }
            'drop-inbound-deny' { $n.Acls = @($n.Acls | Where-Object { -not ($_.Direction -ceq 'Inbound' -and $_.RemoteAddress -ceq '10.0.0.0/8') }) }
            'scoped-deny' { foreach ($r in $n.Acls) { if ($r.Direction -ceq 'Inbound' -and $r.RemoteAddress -ceq '192.168.0.0/16') { $r.Protocol = 'TCP'; $r.LocalPort = '1' } } }
            'stateful-rule' { $n.Acls[0].Stateful = 'True' }
            'isolated-rule' { $n.Acls[0].IsolationId = '7' }
            'no-source-pin' { $n.Acls = @($n.Acls | Where-Object { $_.Action -cne 'Allow' }) }
            'pin-above-deny' { foreach ($r in $n.Acls) { if ($r.Action -ceq 'Allow') { $r.Weight = 50 } } }
            'extra-allow' { $n.Acls = @($n.Acls) + @(New-AapFakeNetRule 'Allow' 'Outbound' ([string]$d.gateway) 100) }
        }
        $n
    }
}

function Set-AapFakeHostNetworkKnob {
    <# Tampers change the simulated host, so Verify and the read-back both see them; faults make an op throw
       (AttachAfterIntent: Attach stops after its intent record; AttachAfterAct: after the adapter exists, before the record
       says attached; DetachAfterReleased: Detach stops after the released list, before the record goes; as a crash would);
       a pause makes an op wait for the test (AttachBeforeAct: the first Attach to get there, its checks done and its VM
       lifecycle lock held, writes barrier\AttachBeforeAct.reached before its act and waits for barrier\AttachBeforeAct.go;
       later ones pass), which places another call exactly between two steps of it. Each call replaces all three lists. #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Tamper = @(), [string[]]$Fail = @(), [string[]]$Pause = @())
    $unknown = @(@($Tamper | Where-Object { $script:TamperNames -cnotcontains $_ }) + @($Fail | Where-Object { $script:FailNames -cnotcontains $_ }) + @($Pause | Where-Object { $script:PauseNames -cnotcontains $_ }))
    if ($unknown.Count) { throw "fake: unknown tamper, fault or pause: $($unknown -join ', ')" }   # check:knob-names
    [IO.File]::WriteAllText((Join-Path $Root 'knobs.json'), (@{ tamper = @($Tamper); fail = @($Fail); pause = @($Pause) } | ConvertTo-Json), $script:Utf8)
}

function Get-AapFakeHostNetworkRecord {
    # The journal records under -Root (with -VmId, that VM's only), as the module keeps them.
    param([Parameter(Mandatory)][string]$Root, [string]$VmId)
    if (-not $VmId) { return Get-AapFakeNetRecords $Root }
    $r = Read-AapFakeNetRecord $Root $VmId
    if ($null -ne $r) { $r }
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

function Add-AapFakeNetAttachment([string]$Root, $q, $Vm, [string[]]$Fail) {
    if ($null -eq $Vm) { throw "AAP_NetworkUntrusted: VM $($q.VmId) does not exist" }   # check:attach-vm
    if ([string]$Vm.State -cne 'Off') { throw "AAP_NetworkUntrusted: VM $($q.VmId) is $($Vm.State), not Off" }   # check:attach-off
    if ($Vm.Adapters -ne 0) { throw "AAP_NetworkUntrusted: VM $($q.VmId) has a network adapter Attach did not make" }   # check:attach-foreign-adapter
    $lock = Enter-AapFakeNetLock $Root
    try {
        # The released list first, then every record, under the lock: one it cannot read stops every Attach, a repeated one
        # too (the address it holds, or the order of reuse, is unknown).
        $released = @(Read-AapFakeNetReleased $Root)
        $all = @(Get-AapFakeNetRecords $Root)
        $rec = @($all | Where-Object { $_.declaration.vm_id -ceq $q.VmId }) | Select-Object -First 1
        if ($null -ne $rec -and ($rec.declaration.vm_name -cne $q.VmName -or $rec.declaration.profile -cne $q.Profile)) {   # check:attach-same-vm
            throw "AAP_NetworkUntrusted: VM $($q.VmId) is recorded as $($rec.declaration.vm_name) ($($rec.declaration.profile))"
        }
        # One MAC, one VM (contract, Attach): a record whose MAC another record holds too, however its text is written, stops
        # its Attach before anything on the host changes; the owner repairs the journal. Both records' Attach stop.
        if ($null -ne $rec) {
            $macTwins = @($all | Where-Object { $_.declaration.vm_id -cne $q.VmId -and (Get-AapFakeNetMacKey ([string]$_.declaration.mac)) -ceq (Get-AapFakeNetMacKey ([string]$rec.declaration.mac)) } |
                    ForEach-Object { [string]$_.declaration.vm_name })
            if ($macTwins.Count) { throw "AAP_NetworkUntrusted: the MAC $($rec.declaration.mac) of VM $($q.VmId) is also held by $($macTwins -join ', '); an owner repairs the journal" }   # check:attach-mac-twin
        }
        if ($null -eq $rec) {
            $sw = Get-AapHostNetworkSwitchName $q.VmName
            $others = @($all | Where-Object { (Get-AapHostNetworkSwitchName ([string]$_.declaration.vm_name)) -ceq $sw })
            # A build VM shares its switch with no VM (contract, Switches): refused while another record names that switch.
            if ($sw -clike 'aap-build-*' -and $others.Count) { throw "AAP_NetworkUntrusted: $sw already carries $(@($others | ForEach-Object { $_.declaration.vm_name }) -join ', ')" }   # check:attach-peers
            $n = $script:Net[$sw]
            $address = Get-AapFakeNetFreeAddress $n @($others | ForEach-Object { [string]$_.declaration.address }) $released
            if (-not $address) { throw "AAP_NetworkUntrusted: no free address on $sw" }   # check:attach-exhausted
            # The static MAC of the module's range, before the VM's first start (contract, Attach; Open points, 1): the
            # lowest that no record holds, no released list for MACs, so the host's neighbour entry pins the address to it.
            $mac = Get-AapFakeNetFreeMac @($all | ForEach-Object { [string]$_.declaration.mac })
            # Intent before act: the record names the declaration and what Attach creates before anything changes.
            $decl = [ordered]@{ schema = 2; kind = 'host_network_attach'; vm_id = $q.VmId; vm_name = $q.VmName; profile = $q.Profile; subnet = $n.Subnet
                gateway = $n.Gateway; address = $address; mac = $mac; resolvers = $script:Resolvers; endpoints = @()
            }
            Write-AapFakeNetRecord $Root ([ordered]@{ schema = 2; kind = 'host_network_record'; state = 'attaching'; declaration = $decl; created = @([ordered]@{ kind = 'adapter'; name = "aap-guest-$($q.VmId)" }, [ordered]@{ kind = 'neighbor'; name = "aap-neighbor-$($q.VmId)" }) })
            $rec = Read-AapFakeNetRecord $Root $q.VmId
        }
    } finally { $lock.Dispose() }
    if ($Fail -ccontains 'AttachAfterIntent') { throw 'AAP_NetworkUntrusted: fake: Attach stopped after its intent record' }
    # The test's scheduler (the pause knob): the checks are done and the VM's lifecycle lock is held, the act has not started, so
    # a Detach of this VM started now can only wait for this call to return.
    Wait-AapFakeNetBarrier $Root 'AttachBeforeAct' @((Read-AapFakeNetKnobs $Root).pause)
    # What the host holds for the guest's address on every interface, read as Verify reads it and before anything is changed
    # (contract, Attach): a read that fails is a throw, never read as no entry; none, or exactly the record's entry (a repeated
    # Attach), is what Attach goes on from; any other entry (another MAC, State or interface, or more than one) is somebody
    # else's, and Attach throws and never returns success: it does not overwrite it.
    $tamper = @((Read-AapFakeNetKnobs $Root).tamper)
    $entrySwitch = Get-AapHostNetworkSwitchName ([string]$rec.declaration.vm_name)
    $held = Read-AapFakeNetNeighbor $Root ([string]$rec.declaration.address) $entrySwitch $tamper
    if ($null -eq $held) { throw "AAP_NetworkUntrusted: the host's neighbour table for VM $($q.VmId) cannot be read: cannot look" }   # check:attach-neighbor-read
    if ($held.Count -and -not (Test-AapFakeNetNeighborIsRecords $held $rec.declaration)) { throw "AAP_NetworkUntrusted: the host already holds an entry for $($rec.declaration.address) that is not the record's; Attach does not overwrite it" }   # check:attach-neighbor-foreign
    # The act: the adapter, its guards and its port ACLs (the simulated host derives them from the record), and with them,
    # idempotently (a repeated Attach completes what the record names), the host's permanent neighbour entry that pairs the
    # guest's address with the declared MAC on the switch's management adapter (contract, Attach); an identical entry already
    # there stays as it is. What the add left in the table is read back: an entry the host does not show as the record's is a
    # failed Attach, and the record stays attaching for a retry.
    [IO.File]::WriteAllText((Get-AapFakeNetHostPath $Root $q.VmId), 'adapter', $script:Utf8)
    if (-not $held.Count) {
        Write-AapFakeNetNeighbor $Root $rec.declaration $tamper
        $added = Read-AapFakeNetNeighbor $Root ([string]$rec.declaration.address) $entrySwitch $tamper
        if ($null -eq $added -or -not (Test-AapFakeNetNeighborIsRecords $added $rec.declaration)) { throw "AAP_NetworkUntrusted: the host's table does not show the entry added for $($rec.declaration.address) as the record's" }   # check:attach-neighbor-verify
    }
    if ($Fail -ccontains 'AttachAfterAct') { throw 'AAP_NetworkUntrusted: fake: Attach stopped after its act' }
    if ($rec.state -cne 'attached') {
        $rec.state = 'attached'
        $lock = Enter-AapFakeNetLock $Root
        try { Write-AapFakeNetRecord $Root $rec } finally { $lock.Dispose() }
    }
    $rec.declaration
}

function Remove-AapFakeNetAttachment([string]$Root, $q, $Vm, [string[]]$Fail) {
    if ($null -ne $Vm) { throw "AAP_NetworkUntrusted: VM $($q.VmId) still exists; remove the VM before Detach" }   # check:detach-order
    $lock = Enter-AapFakeNetLock $Root
    try {
        # The released list first: one it cannot read stops every Detach before anything changes, one with no record too.
        $released = @(Read-AapFakeNetReleased $Root)
        $rec = Read-AapFakeNetRecord $Root $q.VmId
        if ($null -eq $rec) { return }   # never attached, or detached already
        if ($rec.declaration.vm_name -cne $q.VmName -or $rec.declaration.profile -cne $q.Profile) {   # check:detach-same-vm
            throw "AAP_NetworkUntrusted: VM $($q.VmId) is recorded as $($rec.declaration.vm_name) ($($rec.declaration.profile))"
        }
        # The host's permanent neighbour entry goes before the address is released (contract, Detach): the record's own tuple
        # only (its address and MAC on the switch's management adapter), read back, so the removal can never be another VM's or
        # the host's; absent is done, and an entry still there stops this Detach with the record in place and nothing released.
        Remove-AapFakeNetOwnNeighbor $Root $rec.declaration @((Read-AapFakeNetKnobs $Root).tamper)
        if ($Fail -ccontains 'DetachAfterNeighbor') { throw 'AAP_NetworkUntrusted: fake: Detach stopped after the neighbour entry' }
        # The adapter and its port ACLs went with the VM and the per-profile switch is not the VM's: only the record is left,
        # removed by the VM's id, and with it goes the VM's address, now the most recently used. The released list before the
        # record: a crash between them leaves the record, which still holds the address, and a retry finishes.
        $address = [string]$rec.declaration.address
        $released = @(@($released | Where-Object { $_ -cne $address }) + $address)
        $hostPath = Get-AapFakeNetHostPath $Root $q.VmId
        if ([IO.File]::Exists($hostPath)) { [IO.File]::Delete($hostPath) }
        Write-AapFakeNetReleased $Root $released
        if ($Fail -ccontains 'DetachAfterReleased') { throw 'AAP_NetworkUntrusted: fake: Detach stopped after the released list' }
        $path = Get-AapFakeNetRecordPath $Root $q.VmId
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }   # check:detach-removes
    } finally { $lock.Dispose() }
}

# Verify: check 1 from the records, checks 2 to 8 the shared check on the simulated adapter with the fake host's targets, the
# host's neighbour entries for the guest's address, the management adapter's identity and the MACs of the other adapters on
# the switch, check 9 the switch's extensions and HNS networks; never from a knob directly. A record it cannot read, an
# adapter of the module's on an existing VM with no record, a host discovery that found nothing, no gateway or no LAN
# address, a neighbour-table read that fails, or a switch it cannot read: it cannot look.
function Get-AapFakeNetProblem([string]$Root, $q, $Vm, [scriptblock]$VmHook) {
    $id = $q.VmId
    if ($null -eq $Vm) { return "VM $id does not exist" }   # check:verify-vm
    $tamper = @((Read-AapFakeNetKnobs $Root).tamper)
    # The records, the module's adapters and the host's neighbour entries for this VM's address in one view, under the lock:
    # Attach writes a record before its adapter, and its act writes the adapter and the entry together.
    $lock = Enter-AapFakeNetLock $Root
    try {
        $all = @(Get-AapFakeNetRecords $Root)
        $adapters = @(Get-ChildItem -LiteralPath (Join-Path $Root 'host') -File | ForEach-Object { $_.Name })
        $rec = @($all | Where-Object { $_.declaration.vm_id -ceq $id }) | Select-Object -First 1
        $entries = $null
        if ($null -ne $rec) { $entries = Read-AapFakeNetNeighbor $Root ([string]$rec.declaration.address) (Get-AapHostNetworkSwitchName ([string]$rec.declaration.vm_name)) $tamper }
    } finally { $lock.Dispose() }
    # An adapter aap-guest-<id> whose VM exists but has no record (an owner deleted it): nothing would ever detach it, and
    # its address would look free. A removed VM's adapter went with it.
    $known = @($all | ForEach-Object { [string]$_.declaration.vm_id })
    foreach ($a in $adapters) {
        if ($known -cnotcontains $a -and $null -ne (& $VmHook $a)) { throw "AAP_NetworkUntrusted: the adapter aap-guest-$a of an existing VM has no record; remove that VM first: cannot look" }   # check:verify-orphan
    }
    if ($null -eq $rec -or $rec.state -cne 'attached') { return "VM $id is not attached" }   # check:verify-record
    $d = $rec.declaration
    if ($d.vm_name -cne $q.VmName -or $d.profile -cne $q.Profile) { return "VM $id is recorded as $($d.vm_name) ($($d.profile))" }   # check:verify-record
    $sw = Get-AapHostNetworkSwitchName ([string]$d.vm_name)
    $out = New-Object Collections.Generic.List[string]
    # Check 1's twins: no other record on the switch holds the address, and no other record holds the MAC, on any switch and
    # however its text is written: a MAC is the host's key for the neighbour entry and is unique on the host.
    $twins = @($all | Where-Object { $_.declaration.vm_id -cne $id -and $_.declaration.address -ceq $d.address -and (Get-AapHostNetworkSwitchName ([string]$_.declaration.vm_name)) -ceq $sw } |
            ForEach-Object { [string]$_.declaration.vm_name })
    if ($twins.Count) { $out.Add("the address $($d.address) is also held by $($twins -join ', ')") }   # check:verify-address
    $macTwins = @($all | Where-Object { $_.declaration.vm_id -cne $id -and (Get-AapFakeNetMacKey ([string]$_.declaration.mac)) -ceq (Get-AapFakeNetMacKey ([string]$d.mac)) } |
            ForEach-Object { [string]$_.declaration.vm_name })
    if ($macTwins.Count) { $out.Add("the MAC $($d.mac) is also held by $($macTwins -join ', ')") }   # check:verify-mac
    $targets = @(Get-AapFakeNetHostTarget $tamper)
    $lan = @($script:LanAddresses | ForEach-Object { "$_/32" } | Where-Object { $targets -ccontains $_ })
    if ($targets -cnotcontains "$($d.gateway)/32" -or -not $lan.Count) { throw "AAP_NetworkUntrusted: host discovery found $($targets.Count) targets, not the gateway $($d.gateway) and a LAN address: cannot look" }   # check:verify-discovery
    # The host's neighbour entries for the guest's address (contract, Verify check 8): a read that fails is a throw, never
    # read as a definitive no-match (which is check 8's own problem), and Verify never calls the shared check without them.
    if ($null -eq $entries) { throw "AAP_NetworkUntrusted: the host's neighbour table for VM $id cannot be read: cannot look" }   # check:verify-neighbors
    # Check 9's lists: the switch's enabled extensions against the baseline P19 recorded, and the HNS networks on it; a switch
    # Hyper-V does not show them for is not looked at.
    $state = Read-AapFakeNetSwitchState $tamper
    if ($null -eq $state) { throw "AAP_NetworkUntrusted: the extensions of the switch $sw cannot be read: cannot look" }   # check:verify-switch-read
    # The management adapter by identity (its interface index), and the MAC of every other adapter on the switch, which the
    # shared check holds the entry and the adapter's MAC against (checks 2 and 8).
    $hostInterface = @{ InterfaceIndex = [int]$script:Net[$sw].InterfaceIndex; InterfaceAlias = "vEthernet ($sw)" }
    $peerMacs = @(Get-AapFakeNetPeerMac $id $sw $all $adapters ([string]$d.mac) $tamper)
    foreach ($l in @(Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @(Get-AapFakeHostNetworkAdapter -Root $Root -VmId $id) -HostDeny $targets -HostLan $lan -Neighbors $entries -HostInterface $hostInterface -PeerMacs $peerMacs)) { $out.Add([string]$l) }
    foreach ($l in @(Get-AapHostNetworkSwitchProblems -SwitchName $sw -Baseline $state.Baseline -Extensions $state.Extensions -HnsNetworks $state.Hns)) { $out.Add([string]$l) }
    @($out | Select-Object -First 64)
}

# ---- records, the lock, knobs and the fake host --------------------------------------------------------------------------

function Get-AapFakeNetRecordPath([string]$Root, [string]$VmId) { Join-Path $Root "records\$VmId.json" }
function Get-AapFakeNetHostPath([string]$Root, [string]$VmId) { Join-Path $Root "host\$VmId" }

function Read-AapFakeNetRecord([string]$Root, [string]$VmId) {
    $path = Get-AapFakeNetRecordPath $Root $VmId
    if (-not [IO.File]::Exists($path)) { return $null }
    $ok = $false
    try {
        $rec = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        # A record that names a switch P19 owns, or anything not named aap-<words>-<its own VM id> (another VM's rule, a host
        # rule, FPS-SMB-In-TCP-<id>), is not the module's to remove (contract, Detach). Compared ordinally: a case-sensitive,
        # anchored match, never a culture's (which ignores a soft hyphen).
        $owned = '^aap-[a-z]+(-[a-z]+)*-' + [regex]::Escape($VmId) + '\z'
        $ok = $rec.kind -ceq 'host_network_record' -and @('attaching', 'attached') -ccontains $rec.state -and $rec.declaration.vm_id -ceq $VmId -and
            -not @($rec.created | Where-Object { ([string]$_.name) -clike 'aap-guests-*' -or ([string]$_.name) -clike 'aap-build-*' -or ([string]$_.name) -cnotmatch $owned }).Count
        if (-not (Test-AapFakeNetDeclarationShape $rec.declaration)) { $ok = $false }   # check:record-shape
    } catch { $ok = $false }
    if (-not $ok) { throw "AAP_NetworkUntrusted: the record of VM $VmId is unreadable; it stays for an owner" }   # check:record-readable
    $rec
}

# The declaration fields this module reads back from a record (the adapter, its guards and ACLs, the address, the MAC and the
# switch all follow from them): a record whose declaration lacks one, or holds it as anything but text, is as unreadable as one
# that is not JSON, so no later call, a recovery op included, reaches for a field that is not there (contract, Journal). Any text
# will do for the MAC: a test spells it in other forms, and a form that is not canonical is Verify's to refuse, not the journal's.
function Test-AapFakeNetDeclarationShape($Declaration) {
    if ($null -eq $Declaration) { return $false }
    foreach ($k in 'vm_id', 'vm_name', 'profile', 'subnet', 'gateway', 'address', 'mac') {
        if (@($Declaration.PSObject.Properties.Name) -cnotcontains $k) { return $false }
        $v = $Declaration.$k
        if ($v -isnot [string] -or -not $v) { return $false }
    }
    $true
}

# Every record; the first one it cannot read throws.
function Get-AapFakeNetRecords([string]$Root) {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root 'records') -Filter '*.json' -File)) { Read-AapFakeNetRecord $Root $f.BaseName }
}

function Write-AapFakeNetRecord([string]$Root, $Record) {
    Write-AapFakeNetFile (Get-AapFakeNetRecordPath $Root ([string]$Record.declaration.vm_id)) ($Record | ConvertTo-Json -Depth 6)
}

# Written to a temporary name in the same folder and renamed over the old file: a crash leaves the old or the new one,
# never a torn one.
function Write-AapFakeNetFile([string]$Path, [string]$Text) {
    $tmp = [IO.Path]::ChangeExtension($Path, '.tmp')
    [IO.File]::WriteAllText($tmp, $Text, $script:Utf8)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}

# A lock: one exclusive handle on <Root>\<Name> ('lock', the journal lock, unless a VM's lifecycle lock is asked for); a holder
# that dies releases it. Fails closed after a wait. The journal lock is held for every record write and every read of all
# records: a rename over a record may hide its name for a moment.
function Enter-AapFakeNetLock([string]$Root, [string]$Name = 'lock') {
    $until = [DateTime]::UtcNow.AddSeconds($script:LockSeconds)
    $what = $(if ($Name -ceq 'lock') { 'journal lock' } else { "lock $Name" })
    while ($true) {
        try { return [IO.File]::Open((Join-Path $Root $Name), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { if ([DateTime]::UtcNow -gt $until) { throw "AAP_NetworkUntrusted: the $what stayed taken for $($script:LockSeconds) s" } }
        Start-Sleep -Milliseconds 15
    }
}

# The released list; one it cannot read (not a JSON list of IPv4 addresses) throws: never guessed, never rebuilt here.
function Read-AapFakeNetReleased([string]$Root) {
    $path = Join-Path $Root 'released.json'
    if (-not [IO.File]::Exists($path)) { return }
    $list = $null
    try { $list = @([IO.File]::ReadAllText($path) | ConvertFrom-Json | ForEach-Object { $_ }) } catch { $list = $null }
    if ($null -eq $list -or @($list | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[0-9]{1,3}(\.[0-9]{1,3}){3}\z' }).Count) {   # check:released-readable
        throw 'AAP_NetworkUntrusted: released.json is unreadable; Attach and Detach stop until the recovery op rebuilds it'
    }
    $list
}
function Write-AapFakeNetReleased([string]$Root, [string[]]$Addresses) {
    Write-AapFakeNetFile (Join-Path $Root 'released.json') (ConvertTo-Json -InputObject @($Addresses))
}

# The least recently used free address of switch $n's subnet: one never released first (lowest), then the one released
# longest ago; nothing when every address but the gateway is held.
function Get-AapFakeNetFreeAddress($n, [string[]]$Held, [string[]]$Released) {
    $base = $n.Subnet.Substring(0, $n.Subnet.LastIndexOf('.'))
    $free = @(1..254 | ForEach-Object { "$base.$_" } | Where-Object { $_ -cne $n.Gateway -and $Held -cnotcontains $_ })
    $released = @($Released)
    $never = @($free | Where-Object { $released -cnotcontains $_ })
    if ($never.Count) { return $never[0] }   # check:alloc-lru
    @($released | Where-Object { $free -ccontains $_ }) | Select-Object -First 1
}

function Read-AapFakeNetKnobs([string]$Root) {
    $path = Join-Path $Root 'knobs.json'
    if (-not [IO.File]::Exists($path)) { return @{ tamper = @(); fail = @(); pause = @() } }
    $k = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $pause = @()
    if (@($k.PSObject.Properties.Name) -ccontains 'pause') { $pause = @($k.pause | Where-Object { $_ }) }
    @{ tamper = @($k.tamper | Where-Object { $_ }); fail = @($k.fail | Where-Object { $_ }); pause = $pause }
}

# A test's scheduler (Set-AapFakeHostNetworkKnob -Pause): with the pause set the first op to get here writes
# barrier\<name>.reached and waits for barrier\<name>.go, so a test places another call exactly between two steps of that one;
# an op that gets here after it passes. It fails closed when no one releases it.
function Wait-AapFakeNetBarrier([string]$Root, [string]$Name, [string[]]$Pause) {
    if ($Pause -cnotcontains $Name) { return }
    $dir = Join-Path $Root 'barrier'
    [void][IO.Directory]::CreateDirectory($dir)
    # Created new: the first op to get here holds the pause; one that finds the file already there passes.
    $reached = Join-Path $dir "$Name.reached"
    try { [IO.File]::Open($reached, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read).Dispose() } catch { if ([IO.File]::Exists($reached)) { return }; throw }
    $until = [DateTime]::UtcNow.AddSeconds($script:BarrierSeconds)
    while (-not [IO.File]::Exists((Join-Path $dir "$Name.go"))) {
        if ([DateTime]::UtcNow -gt $until) { throw "fake: nobody released the pause $Name within $($script:BarrierSeconds) s" }
        Start-Sleep -Milliseconds 15
    }
}

function New-AapFakeNetRule([string]$Action, [string]$Direction, [string]$Remote, [int]$Weight, [string]$Local = 'ANY') {
    @{ Action = $Action; Direction = $Direction; RemoteAddress = $Remote; LocalAddress = $Local; Protocol = 'ANY'; RemotePort = 'ANY'; LocalPort = 'ANY'; Weight = $Weight
        Stateful = 'False'; IsolationId = '0'
    }
}

# What host discovery finds (contract, Verify check 5): the host's addresses (vEthernet and LAN), each vEthernet adapter's
# IPv4 prefix and the LAN IPv6 prefixes. The fixed ranges cover all of them, so the module writes no deny of its own for
# them; the tampers make discovery find a public address, nothing, no gateway, or no LAN address.
function Get-AapFakeNetHostTarget([string[]]$Tamper) {
    if ($Tamper -ccontains 'host-empty') { return }
    $gateways = @($script:Net.Values | ForEach-Object { $_.Gateway })
    $addresses = @(@($script:HostAddresses | Where-Object { -not ($Tamper -ccontains 'host-no-gateway' -and $gateways -ccontains $_) }) +
        @($script:LanAddresses | Where-Object { $Tamper -cnotcontains 'host-no-lan' }) + @(if ($Tamper -ccontains 'public-host') { $script:PublicHost }))
    @($addresses | ForEach-Object { if ($_.Contains(':')) { "$_/128" } else { "$_/32" } }) + $script:OnLink + $script:LanPrefixes
}

# A MAC as its hex digits in upper case: two records hold one MAC however its text is written (contract, Verify check 1).
function Get-AapFakeNetMacKey([string]$Mac) { ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() }

# The lowest static MAC of the module's range (the shared check's Get-AapHostNetworkMacRange) that no record holds
# (contract, Attach): no released list for MACs, a crashed Attach's record holds its MAC as its address until Detach.
function Get-AapFakeNetFreeMac([string[]]$Held) {
    $r = Get-AapHostNetworkMacRange
    $heldKeys = @($Held | ForEach-Object { Get-AapFakeNetMacKey $_ })
    $free = $null
    :scan foreach ($i in 0..255) {
        foreach ($j in 0..255) {
            foreach ($k in 1..255) {
                $m = "$r-$(('{0:X2}' -f $i))-$(('{0:X2}' -f $j))-$(('{0:X2}' -f $k))"
                if ($heldKeys -cnotcontains (Get-AapFakeNetMacKey $m)) { $free = $m; break scan }
            }
        }
    }
    $free
}

# The MAC of every other adapter Hyper-V lists on the VM's switch (contract, Verify check 2): the module's adapters of the
# other VMs there, and the host's own vEthernet adapter. The peer-mac-clash tamper puts one more adapter there that carries
# the VM's own MAC.
function Get-AapFakeNetPeerMac([string]$Id, [string]$SwitchName, $All, [string[]]$AdapterIds, [string]$OwnMac, [string[]]$Tamper) {
    $peers = @($All | Where-Object { $_.declaration.vm_id -cne $Id -and $AdapterIds -ccontains [string]$_.declaration.vm_id -and
            (Get-AapHostNetworkSwitchName ([string]$_.declaration.vm_name)) -ceq $SwitchName } | ForEach-Object { [string]$_.declaration.mac })
    $peers += $script:HostAdapterMac
    if ($Tamper -ccontains 'peer-mac-clash') { $peers += $OwnMac }
    $peers
}

# What the switch shows of its extensions and the host of its HNS networks (contract, Verify check 9): the baseline P19
# recorded and what is enabled now, and the HNS networks on the switch. The switch-unreadable tamper makes the read fail;
# the others change what is enabled (one more, or the baseline's one off) or put an HNS network on the switch.
function Read-AapFakeNetSwitchState([string[]]$Tamper) {
    if ($Tamper -ccontains 'switch-unreadable') { return $null }
    $enabled = @($script:ExtensionBaseline)
    if ($Tamper -ccontains 'switch-extension') { $enabled += $script:ExtraExtension }
    if ($Tamper -ccontains 'switch-extension-off') { $enabled = @() }
    $hns = @()
    if ($Tamper -ccontains 'hns-network') { $hns = @($script:HnsNetwork) }
    @{ Baseline = @($script:ExtensionBaseline); Extensions = $enabled; Hns = $hns }
}

# ---- the host's neighbour table ------------------------------------------------------------------------------------------
# One file per interface and address, as the host's table is keyed (contract, Attach and Detach):
# neighbor\<interface index>-<address>.json holds an entry as Get-NetNeighbor shows it: IPAddress, LinkLayerAddress, State,
# InterfaceAlias, InterfaceIndex. The module's own entry is one of them; the table can hold others (Add-AapFakeHostNetworkNeighbor).
function Get-AapFakeNetNeighborPath([string]$Root, [int]$Index, [string]$Address) { Join-Path $Root "neighbor\$Index-$Address.json" }

# Every entry of the table; a file that is not an entry throws (a read that fails is never read as no entry).
function Get-AapFakeNetTable([string]$Root) {
    $dir = Join-Path $Root 'neighbor'
    if (-not [IO.Directory]::Exists($dir)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File)) { [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json }
}

# The host's entries for the guest's address on every interface (contract, Attach and Verify check 8), as Get-NetNeighbor
# would list them: Attach reads them first and Verify reads them back. The neighbor-unreadable tamper makes the read fail, as
# a Get-NetNeighbor error would (never read as a definitive no-match); the others change what the host shows of the module's
# own entry, the one on the switch's management adapter: none (neighbor-missing), another MAC, a dynamic state, or another
# interface that wears the switch adapter's alias.
function Read-AapFakeNetNeighbor([string]$Root, [string]$Address, [string]$SwitchName, [string[]]$Tamper) {
    # (, @() keeps the empty list a list through the pipeline; a plain return @() would unroll to $null.)
    if ($Tamper -ccontains 'neighbor-unreadable') { return $null }   # check:neighbor-unreadable
    if ($Tamper -ccontains 'neighbor-missing') { return , @() }   # check:neighbor-missing
    $own = $null
    if ($script:Net.ContainsKey($SwitchName)) { $own = [int]$script:Net[$SwitchName].InterfaceIndex }
    $held = @(Get-AapFakeNetTable $Root | Where-Object { [string]$_.IPAddress -ceq $Address } | ForEach-Object {
            $e = [ordered]@{ IPAddress = [string]$_.IPAddress; LinkLayerAddress = [string]$_.LinkLayerAddress; State = [string]$_.State
                InterfaceAlias = [string]$_.InterfaceAlias; InterfaceIndex = [int]$_.InterfaceIndex }
            if ($null -ne $own -and $e.InterfaceIndex -eq $own) {
                switch -CaseSensitive ($Tamper) {
                    'neighbor-mac' { $e.LinkLayerAddress = '02-A0-98-FF-FF-FE' }
                    'neighbor-state' { $e.State = 'Stale' }
                    'neighbor-interface' { $e.InterfaceIndex = 99 }
                }
            }
            [pscustomobject]$e
        })
    , $held
}

# Whether the entries the host holds for the guest's address are exactly the one entry the record names (contract, Attach;
# what Verify's check 8 requires): one, the guest's address, the declared MAC, State Permanent, on the switch's management
# adapter (its interface index and its alias). Anything else is somebody else's entry.
function Test-AapFakeNetNeighborIsRecords($Entries, $d) {
    if (@($Entries).Count -ne 1) { return $false }
    $e = @($Entries)[0]
    $sw = Get-AapHostNetworkSwitchName ([string]$d.vm_name)
    [string]$e.IPAddress -ceq [string]$d.address -and [string]$e.LinkLayerAddress -ceq [string]$d.mac -and [string]$e.State -ceq 'Permanent' -and
        [string]$e.InterfaceIndex -ceq [string]$script:Net[$sw].InterfaceIndex -and [string]$e.InterfaceAlias -ceq "vEthernet ($sw)"
}

# The entry Attach's act writes, from the record: one permanent entry pairing the guest's address with the declared MAC on
# the switch's management adapter (contract, Attach). New-NetNeighbor does not replace an entry that is there: it fails. The
# neighbor-add-lost tamper makes the add report success while the table shows nothing, as a host that dropped it would.
function Write-AapFakeNetNeighbor([string]$Root, $d, [string[]]$Tamper) {
    $sw = Get-AapHostNetworkSwitchName ([string]$d.vm_name)
    $index = [int]$script:Net[$sw].InterfaceIndex
    $path = Get-AapFakeNetNeighborPath $Root $index ([string]$d.address)
    if ([IO.File]::Exists($path)) { throw "AAP_NetworkUntrusted: fake: New-NetNeighbor: the host already holds an entry for $($d.address) on interface $index" }
    if ($Tamper -ccontains 'neighbor-add-lost') { return }
    $e = [ordered]@{ IPAddress = [string]$d.address; LinkLayerAddress = [string]$d.mac; State = 'Permanent'; InterfaceAlias = "vEthernet ($sw)"; InterfaceIndex = $index }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $e), $script:Utf8)
}

# A read of the host's table that fails (the neighbor-unreadable tamper, as a Get-NetNeighbor error would) is a throw, never
# read as no entry (contract, Detach and the recovery ops), as it is for Attach and Verify.
function Assert-AapFakeNetTableReadable([string[]]$Tamper) {
    if ($Tamper -ccontains 'neighbor-unreadable') { throw "AAP_NetworkUntrusted: the host's neighbour table cannot be read: cannot look" }   # check:neighbor-table-read
}

# Removes one entry and reads the table back (contract, Detach): an entry still there afterwards (the neighbor-stuck tamper
# keeps the removal from taking effect, as a host that failed to apply it would) is a throw, and nothing after it is done.
function Remove-AapFakeNetEntryVerified([string]$Root, [int]$Index, [string]$Address, [string]$Mac, [string[]]$Tamper) {
    $path = Get-AapFakeNetNeighborPath $Root $Index $Address
    if ($Tamper -cnotcontains 'neighbor-stuck') { [IO.File]::Delete($path) }   # check:detach-neighbor
    if ([IO.File]::Exists($path)) { throw "AAP_NetworkUntrusted: the host still holds the entry for $Address ($Mac) on interface $Index after its removal" }   # check:detach-neighbor-verify
}

# Detach's own entry, by the exact tuple (contract, Detach): the record's address and MAC on the switch's management adapter,
# in any state. Anything else the table holds for the address (another interface, another MAC) is not the record's and stays;
# absent is done; a table that cannot be read is a throw.
function Remove-AapFakeNetOwnNeighbor([string]$Root, $d, [string[]]$Tamper) {
    Assert-AapFakeNetTableReadable $Tamper
    $sw = Get-AapHostNetworkSwitchName ([string]$d.vm_name)
    $index = [int]$script:Net[$sw].InterfaceIndex
    $path = Get-AapFakeNetNeighborPath $Root $index ([string]$d.address)
    if (-not [IO.File]::Exists($path)) { return }
    $e = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ([string]$e.LinkLayerAddress -cne [string]$d.mac) { return }   # check:detach-neighbor-scope
    Remove-AapFakeNetEntryVerified $Root $index ([string]$d.address) ([string]$d.mac) $Tamper
}

# The (interface, address, MAC) tuple of an entry as one comparable text.
function Get-AapFakeNetTupleKey($e) { "$([string]$e.InterfaceIndex)|$([string]$e.IPAddress)|$([string]$e.LinkLayerAddress)" }

# The tuples the readable records name: what their Attach adds and their Detach removes. A record that cannot be read names
# none (an owner reads it).
function Get-AapFakeNetNamedTuple([string]$Root) {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Root 'records') -Filter '*.json' -File)) {
        $r = $null
        try { $r = Read-AapFakeNetRecord $Root $f.BaseName } catch { continue }
        if ($null -eq $r) { continue }
        $sw = Get-AapHostNetworkSwitchName ([string]$r.declaration.vm_name)
        if (-not $script:Net.ContainsKey($sw)) { continue }
        "$([string]$script:Net[$sw].InterfaceIndex)|$([string]$r.declaration.address)|$([string]$r.declaration.mac)"
    }
}

function Get-AapFakeHostNetworkNeighbor {
    <# The host's neighbour table under -Root as Get-NetNeighbor lists it (with -IPAddress, that address's entries only): what
       the host holds, for a test to look at. #>
    param([Parameter(Mandatory)][string]$Root, [string]$IPAddress)
    $t = @(Get-AapFakeNetTable $Root)
    if ($IPAddress) { $t = @($t | Where-Object { [string]$_.IPAddress -ceq $IPAddress }) }
    $t
}

function Add-AapFakeHostNetworkNeighbor {
    <# Plants an entry the module did not add (one the host learned, one a deleted record left behind): the table holds one
       entry per interface and address, so one already there throws. The alias is the interface's, the switch's vEthernet
       adapter for the module's interfaces. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$IPAddress, [Parameter(Mandatory)][string]$LinkLayerAddress,
        [string]$State = 'Stale', [int]$InterfaceIndex = 31)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'neighbor'))
    $alias = "Ethernet $InterfaceIndex"
    foreach ($s in $script:Net.Keys) { if ([int]$script:Net[$s].InterfaceIndex -eq $InterfaceIndex) { $alias = "vEthernet ($s)" } }
    $path = Get-AapFakeNetNeighborPath $Root $InterfaceIndex $IPAddress
    if ([IO.File]::Exists($path)) { throw "fake: the table already holds an entry for $IPAddress on interface $InterfaceIndex" }
    $e = [ordered]@{ IPAddress = $IPAddress; LinkLayerAddress = $LinkLayerAddress; State = $State; InterfaceAlias = $alias; InterfaceIndex = $InterfaceIndex }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $e), $script:Utf8)
}

function Get-AapFakeHostNetworkOrphan {
    <# The module's recovery listing (contract, Journal): the permanent entries of the module's MAC range on its own interfaces
       that no readable record names, as Get-NetNeighbor shows them. What a deleted or unreadable record left on the host. A
       table that cannot be read is a throw. #>
    param([Parameter(Mandatory)][string]$Root)
    Assert-AapFakeNetTableReadable @((Read-AapFakeNetKnobs $Root).tamper)
    $lock = Enter-AapFakeNetLock $Root
    try { $named = @(Get-AapFakeNetNamedTuple $Root); $table = @(Get-AapFakeNetTable $Root) } finally { $lock.Dispose() }
    $indexes = @($script:Net.Values | ForEach-Object { [string]$_.InterfaceIndex })
    @($table | Where-Object { [string]$_.State -ceq 'Permanent' -and ([string]$_.LinkLayerAddress) -clike "$(Get-AapHostNetworkMacRange)-*" -and
            $indexes -ccontains [string]$_.InterfaceIndex -and $named -cnotcontains (Get-AapFakeNetTupleKey $_) })
}

function Remove-AapFakeHostNetworkNeighbor {
    <# The module's recovery op for an entry no record names (contract, Journal): an owner's explicit step, never part of Attach,
       Detach or Verify. It removes exactly the tuple it is given, the interface, the address and the MAC, and nothing else: the
       MAC must be of the module's range and the interface the management adapter of one of its switches (what the listing
       names), no readable record may name the tuple (that record's Detach removes it), the entry there must carry the MAC
       given, and the table is read back. An entry already absent is done; a table that cannot be read is a throw. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$IPAddress, [Parameter(Mandatory)][string]$LinkLayerAddress, [Parameter(Mandatory)][int]$InterfaceIndex)
    if ($LinkLayerAddress -cnotlike "$(Get-AapHostNetworkMacRange)-*") { throw "AAP_NetworkUntrusted: $LinkLayerAddress is not a MAC of the module's range: its entries are not the module's to remove" }   # check:recover-range
    if (@($script:Net.Values | ForEach-Object { [int]$_.InterfaceIndex }) -notcontains $InterfaceIndex) { throw "AAP_NetworkUntrusted: interface $InterfaceIndex is not the management adapter of one of the module's switches: its entries are not the module's to remove" }   # check:recover-interface
    $lock = Enter-AapFakeNetLock $Root
    try {
        $named = @(Get-AapFakeNetNamedTuple $Root)
        if ($named -ccontains "$InterfaceIndex|$IPAddress|$LinkLayerAddress") { throw "AAP_NetworkUntrusted: a record names the entry for $IPAddress; its Detach removes it, not the recovery op" }   # check:recover-named
        Assert-AapFakeNetTableReadable @((Read-AapFakeNetKnobs $Root).tamper)
        $path = Get-AapFakeNetNeighborPath $Root $InterfaceIndex $IPAddress
        if (-not [IO.File]::Exists($path)) { return }
        $e = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ([string]$e.LinkLayerAddress -cne $LinkLayerAddress) { throw "AAP_NetworkUntrusted: the entry for $IPAddress on interface $InterfaceIndex carries another MAC: not the entry named" }   # check:recover-exact
        Remove-AapFakeNetEntryVerified $Root $InterfaceIndex $IPAddress $LinkLayerAddress @((Read-AapFakeNetKnobs $Root).tamper)
    } finally { $lock.Dispose() }
}

function Repair-AapFakeHostNetworkReleased {
    <# The module's recovery op for an unreadable released.json (contract, Journal): an owner's explicit step, never part of
       Attach, Detach or Verify. Under the lock, from every record (one it cannot read throws), it writes the list anew: each
       switch's addresses that no record holds, lowest first (the old order is lost). #>
    param([Parameter(Mandatory)][string]$Root)
    $lock = Enter-AapFakeNetLock $Root
    try {
        $held = @(Get-AapFakeNetRecords $Root | ForEach-Object { [string]$_.declaration.address })
        $free = @(foreach ($n in @($script:Net.Values | Sort-Object { $_.Subnet })) {
                $base = $n.Subnet.Substring(0, $n.Subnet.LastIndexOf('.'))
                1..254 | ForEach-Object { "$base.$_" } | Where-Object { $_ -cne $n.Gateway -and $held -cnotcontains $_ }
            })
        Write-AapFakeNetReleased $Root $free
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function New-AapFakeHostNetwork, Invoke-AapFakeHostNetwork, Get-AapFakeHostNetworkAdapter, Set-AapFakeHostNetworkKnob,
    Get-AapFakeHostNetworkRecord, Repair-AapFakeHostNetworkReleased, Get-AapFakeHostNetworkNeighbor, Add-AapFakeHostNetworkNeighbor,
    Get-AapFakeHostNetworkOrphan, Remove-AapFakeHostNetworkNeighbor
