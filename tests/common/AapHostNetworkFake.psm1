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
#   host\<vm id>          the simulated host: the VM has the module's adapter (its guards and ACLs follow from the record)
#   knobs.json            tampers (changes to the simulated host, seen by Verify and the read-back alike) and faults
# Nothing here calls Hyper-V or the network.
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
$script:OnLink = @('172.31.250.0/24', '172.31.251.0/24', '172.31.252.0/24', '172.31.253.0/24', '172.29.16.0/20')   # each vEthernet adapter's IPv4 prefix
$script:LanPrefixes = @('2001:db8:1::/64')
$script:LanAddresses = @('192.168.1.10')   # the host's own address on its LAN card, not a vEthernet adapter
$script:PublicHost = '203.0.113.7'   # what the public-host tamper gives the host
$script:Weight = @{ CatchAll = 1; Pin = 5; Deny = 10 }   # one per rule class (contract, Rules and weights); no endpoint, so no endpoint allow
$script:LockSeconds = 30
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:TamperNames = @('no-adapter', 'second-adapter', 'external-switch', 'other-switch', 'dhcp-guard-off', 'router-guard-off', 'mac-spoofing-on',
    'port-mirroring', 'vlan-trunk', 'storm-limit-off', 'legacy-acl', 'foreign-peer', 'drop-fixed-deny', 'drop-inbound-deny', 'scoped-deny', 'stateful-rule',
    'isolated-rule', 'no-source-pin', 'pin-above-deny', 'extra-allow', 'public-host', 'host-empty', 'host-no-gateway', 'host-no-lan')
$script:FailNames = @('Attach', 'AttachAfterIntent', 'AttachAfterAct', 'Detach', 'DetachAfterReleased', 'Verify')
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function New-AapFakeHostNetwork {
    <# The module's interface on the fake host. -Vm answers what Hyper-V has for the VM id it is given: $null only when
       Hyper-V definitively has no such VM, else @{ State = 'Off', 'Running', ...; Adapters = <its adapters the module did not
       make> }; it throws when it cannot look, and so does the call. The consumer's own fake world owns the VMs. #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Vm)
    foreach ($sub in 'records', 'host') { [void][IO.Directory]::CreateDirectory((Join-Path $Root $sub)) }
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
    $have = & $Vm $q.VmId
    switch ($Op) {
        'Attach' { Add-AapFakeNetAttachment $Root $q $have $fail }
        'Detach' { Remove-AapFakeNetAttachment $Root $q $have $fail }
        'Verify' { Get-AapFakeNetProblem $Root $q $have $Vm }
    }
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
        $n = @{ SwitchName = $sw; SwitchType = 'Internal'; DhcpGuard = 'On'; RouterGuard = 'On'; MacAddressSpoofing = 'Off'; PortMirroringMode = 'None'; VlanMode = 'Untagged'
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
       says attached; DetachAfterReleased: Detach stops after the released list, before the record goes; as a crash would).
       Each call replaces both lists. #>
    param([Parameter(Mandatory)][string]$Root, [string[]]$Tamper = @(), [string[]]$Fail = @())
    $unknown = @(@($Tamper | Where-Object { $script:TamperNames -cnotcontains $_ }) + @($Fail | Where-Object { $script:FailNames -cnotcontains $_ }))
    if ($unknown.Count) { throw "fake: unknown tamper or fault: $($unknown -join ', ')" }   # check:knob-names
    [IO.File]::WriteAllText((Join-Path $Root 'knobs.json'), (@{ tamper = @($Tamper); fail = @($Fail) } | ConvertTo-Json), $script:Utf8)
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
        if ($null -eq $rec) {
            $sw = Get-AapHostNetworkSwitchName $q.VmName
            $others = @($all | Where-Object { (Get-AapHostNetworkSwitchName ([string]$_.declaration.vm_name)) -ceq $sw })
            # A build VM shares its switch with no VM (contract, Switches): refused while another record names that switch.
            if ($sw -clike 'aap-build-*' -and $others.Count) { throw "AAP_NetworkUntrusted: $sw already carries $(@($others | ForEach-Object { $_.declaration.vm_name }) -join ', ')" }   # check:attach-peers
            $n = $script:Net[$sw]
            $address = Get-AapFakeNetFreeAddress $n @($others | ForEach-Object { [string]$_.declaration.address }) $released
            if (-not $address) { throw "AAP_NetworkUntrusted: no free address on $sw" }   # check:attach-exhausted
            # Intent before act: the record names the declaration and what Attach creates before anything changes.
            $decl = [ordered]@{ schema = 1; kind = 'host_network_attach'; vm_id = $q.VmId; vm_name = $q.VmName; profile = $q.Profile; subnet = $n.Subnet
                gateway = $n.Gateway; address = $address; resolvers = $script:Resolvers; endpoints = @()
            }
            Write-AapFakeNetRecord $Root ([ordered]@{ schema = 1; kind = 'host_network_record'; state = 'attaching'; declaration = $decl; created = @([ordered]@{ kind = 'adapter'; name = "aap-guest-$($q.VmId)" }) })
            $rec = Read-AapFakeNetRecord $Root $q.VmId
        }
    } finally { $lock.Dispose() }
    if ($Fail -ccontains 'AttachAfterIntent') { throw 'AAP_NetworkUntrusted: fake: Attach stopped after its intent record' }
    # The act: the adapter, its guards and its port ACLs; the simulated host derives them from the record.
    [IO.File]::WriteAllText((Get-AapFakeNetHostPath $Root $q.VmId), 'adapter', $script:Utf8)
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

# Verify: check 1 from the records, checks 2 to 7 the shared check on the simulated adapter with the fake host's targets;
# never from a knob directly. A record it cannot read, an adapter of the module's on an existing VM with no record, or a host
# discovery that found nothing, no gateway or no LAN address: it cannot look.
function Get-AapFakeNetProblem([string]$Root, $q, $Vm, [scriptblock]$VmHook) {
    $id = $q.VmId
    if ($null -eq $Vm) { return "VM $id does not exist" }   # check:verify-vm
    # The records and the module's adapters in one view, under the lock: Attach writes a record before its adapter.
    $lock = Enter-AapFakeNetLock $Root
    try {
        $all = @(Get-AapFakeNetRecords $Root)
        $adapters = @(Get-ChildItem -LiteralPath (Join-Path $Root 'host') -File | ForEach-Object { $_.Name })
    } finally { $lock.Dispose() }
    # An adapter aap-guest-<id> whose VM exists but has no record (an owner deleted it): nothing would ever detach it, and
    # its address would look free. A removed VM's adapter went with it.
    $known = @($all | ForEach-Object { [string]$_.declaration.vm_id })
    foreach ($a in $adapters) {
        if ($known -cnotcontains $a -and $null -ne (& $VmHook $a)) { throw "AAP_NetworkUntrusted: the adapter aap-guest-$a of an existing VM has no record; remove that VM first: cannot look" }   # check:verify-orphan
    }
    $rec = @($all | Where-Object { $_.declaration.vm_id -ceq $id }) | Select-Object -First 1
    if ($null -eq $rec -or $rec.state -cne 'attached') { return "VM $id is not attached" }   # check:verify-record
    $d = $rec.declaration
    if ($d.vm_name -cne $q.VmName -or $d.profile -cne $q.Profile) { return "VM $id is recorded as $($d.vm_name) ($($d.profile))" }   # check:verify-record
    $sw = Get-AapHostNetworkSwitchName ([string]$d.vm_name)
    $twins = @($all | Where-Object { $_.declaration.vm_id -cne $id -and $_.declaration.address -ceq $d.address -and (Get-AapHostNetworkSwitchName ([string]$_.declaration.vm_name)) -ceq $sw } |
            ForEach-Object { [string]$_.declaration.vm_name })
    if ($twins.Count) { "the address $($d.address) is also held by $($twins -join ', ')" }   # check:verify-address
    $targets = @(Get-AapFakeNetHostTarget @((Read-AapFakeNetKnobs $Root).tamper))
    $lan = @($script:LanAddresses | ForEach-Object { "$_/32" } | Where-Object { $targets -ccontains $_ })
    if ($targets -cnotcontains "$($d.gateway)/32" -or -not $lan.Count) { throw "AAP_NetworkUntrusted: host discovery found $($targets.Count) targets, not the gateway $($d.gateway) and a LAN address: cannot look" }   # check:verify-discovery
    Get-AapHostNetworkAdapterProblems -Declaration $d -Adapters @(Get-AapFakeHostNetworkAdapter -Root $Root -VmId $id) -HostDeny $targets -HostLan $lan
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
    } catch { $ok = $false }
    if (-not $ok) { throw "AAP_NetworkUntrusted: the record of VM $VmId is unreadable; it stays for an owner" }   # check:record-readable
    $rec
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

# The journal lock: one exclusive handle on <Root>\lock; a holder that dies releases it. Fails closed after a wait. Held for
# every record write and every read of all records: a rename over a record may hide its name for a moment.
function Enter-AapFakeNetLock([string]$Root) {
    $until = [DateTime]::UtcNow.AddSeconds($script:LockSeconds)
    while ($true) {
        try { return [IO.File]::Open((Join-Path $Root 'lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { if ([DateTime]::UtcNow -gt $until) { throw "AAP_NetworkUntrusted: the journal lock stayed taken for $($script:LockSeconds) s" } }
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
    if (-not [IO.File]::Exists($path)) { return @{ tamper = @(); fail = @() } }
    $k = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    @{ tamper = @($k.tamper | Where-Object { $_ }); fail = @($k.fail | Where-Object { $_ }) }
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
    Get-AapFakeHostNetworkRecord, Repair-AapFakeHostNetworkReleased
