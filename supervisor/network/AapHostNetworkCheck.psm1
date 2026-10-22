# Shared check of the P10.0 host network module's work (parity/contracts/host-network-module.md, Shared check): the
# declaration Attach returns, and Hyper-V's read-back of a VM's adapters against it. Pure: no Hyper-V, file, registry or
# network call. Each check returns problem lines (printable, at most 200 characters, at most 64); none means it holds. The
# one implementation for every consumer: the image builders (P06, P07), the VM backends (P10, P11), the module's own Verify
# and the shared fake (tests/common/AapHostNetworkFake.psm1). Windows PowerShell 5.1 and PowerShell 7.
# Lines tagged '# check:<name>' are the checks tests/common/Invoke-AapHostNetworkMutations.ps1 disables one at a time.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# guest-transport.md's fixed deny ranges in canonical text: the only copy. The module writes them, every read-back checks
# them. Guests have and need no IPv6: '::/0' also covers every IPv6 form of an IPv4 address and the host's IPv6 prefixes.
$script:FixedDeny = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', 'ff00::/8', 'fe80::/10', 'fc00::/7', '255.255.255.255/32', '0.0.0.0/8', '127.0.0.0/8', '240.0.0.0/4', '::/0')
# The fixed ranges a NAT routes unicast in: where a subnet and a private resolver may lie.
$script:PrivateRanges = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10')
# The 3-byte prefix of every static MAC the module gives a guest (contract, Attach; Open points, 1): locally administered,
# outside every registered OUI and Hyper-V's dynamic pool. The one copy: validate.py reads it from here.
$script:MacRange = '02-A0-98'
$script:StormLimit = '100'   # broadcast, multicast and unknown unicast packets per second (contract, Rules and weights; D2)
$script:Directions = @('Inbound', 'Outbound')   # an extended port ACL has no 'Both'
$script:AdapterKeys = @('SwitchName', 'SwitchType', 'MacAddress', 'DhcpGuard', 'RouterGuard', 'MacAddressSpoofing', 'PortMirroringMode', 'VlanMode', 'StormLimit', 'LegacyAcls', 'Peers', 'Acls')
$script:RuleKeys = @('Action', 'Direction', 'RemoteAddress', 'LocalAddress', 'Protocol', 'RemotePort', 'LocalPort', 'Weight', 'Stateful', 'IsolationId')
$script:DeclarationKeys = @('schema', 'kind', 'vm_id', 'vm_name', 'profile', 'subnet', 'gateway', 'address', 'mac', 'resolvers', 'endpoints')
$script:EndpointKeys = @('address', 'protocol', 'port')
$script:NeighborKeys = @('IPAddress', 'LinkLayerAddress', 'State', 'InterfaceAlias', 'InterfaceIndex')
$script:GuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:NameRe = '^aap-([wl])(-[1-5]-[0-9]{1,9}-|build-)[0-9a-f]{8}\z'

function Get-AapHostNetworkFixedDeny {
    # The ranges every guest adapter denies, inbound and outbound, unscoped.
    $script:FixedDeny
}

function Get-AapHostNetworkMacRange {
    <# The 3-byte prefix of the module's static-MAC range (contract, Attach): the range the module allocates a guest's
       `mac` from, for the module and the shared fake. #>
    $script:MacRange
}

function Get-AapHostNetworkSwitchName {
    <# The switch a VM's one adapter belongs on (contract, Switches): a runner clone on its profile's guest switch, a build VM
       on its profile's build switch; '' for any other name (verification and scanner VMs have no adapter). #>
    param([AllowNull()][AllowEmptyString()][string]$VmName)
    if ($VmName -cmatch $script:NameRe) {
        $p = $(if ($Matches[1] -ceq 'w') { 'win' } else { 'linux' })
        $(if ($Matches[2] -ceq 'build-') { "aap-build-$p" } else { "aap-guests-$p" })
    } else { '' }
}

function Get-AapHostNetworkDeclarationProblems {
    <# Attach's return value against the request it answered (contract, Declaration check). Any line: AAP_NetworkInvalid. #>
    param([Parameter(Mandatory)][AllowNull()]$Request, [Parameter(Mandatory)][AllowNull()]$Declaration)
    @(Get-AapNetDeclarationProblem $Request $Declaration) | ForEach-Object { Format-AapNetText $_ 197 } | Select-Object -First 64
}

function Get-AapHostNetworkAdapterProblems {
    <# Hyper-V's read-back of a VM's adapters (the provider shape, contract Read-back) against the declaration Attach returned.
       HostDeny: the host's addresses and prefixes (Verify check 5), which the host-specific denies must cover and no
       endpoint may lie in; only the module knows the host, so its Verify passes them and consumers do not. Given, it must
       hold the declaration's gateway and, as HostLan, at least one address of a host interface that is not a vEthernet
       adapter (an empty or partial discovery cannot pass). Neighbors: the host's neighbour entries for the guest's address
       (Verify check 8), each as Get-NetNeighbor shows it (IPAddress, LinkLayerAddress, State, InterfaceAlias, InterfaceIndex);
       the module's own Verify passes them and a consumer never does. Given, exactly one entry, State Permanent, with the
       declared `mac`, on the switch's management adapter is required. HostInterface is that adapter as the module resolved
       it by identity, never by its name (@{ InterfaceIndex; InterfaceAlias }): the entry must carry both, and with no
       resolved adapter the entry has nothing to be held against, which is a problem. PeerMacs: the MAC of every other adapter
       on the VM's switch, the host's own among them (Verify check 2); given, it must list at least one (the host's own
       adapter is always on the switch) and every entry must be a MAC (twelve hex digits: in pairs joined by dashes or colons,
       or run together), and none may be the declared `mac` (compared as hex digits, however written): a null, empty or
       malformed list is a discovery that failed and cannot establish uniqueness, so it is a problem, never "no other adapter".
       Only the module reads every adapter and the host, so only its Verify passes these.
       Any line: AAP_NetworkUntrusted. #>
    param([Parameter(Mandatory)][AllowNull()]$Declaration, [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Adapters,
        [AllowEmptyCollection()][string[]]$HostDeny, [AllowEmptyCollection()][string[]]$HostLan, [AllowEmptyCollection()][object[]]$Neighbors,
        [AllowNull()]$HostInterface, [AllowNull()][AllowEmptyCollection()][string[]]$PeerMacs)
    $targets = $null
    if ($PSBoundParameters.ContainsKey('HostDeny') -or $PSBoundParameters.ContainsKey('HostLan')) { $targets = [string[]]@($HostDeny) }
    $entries = $null
    if ($PSBoundParameters.ContainsKey('Neighbors')) { $entries = [object[]]@($Neighbors) }   # check:neighbor-given
    $peers = $null
    if ($PSBoundParameters.ContainsKey('PeerMacs')) {   # check:peer-given
        if ($null -eq $PeerMacs) { $peers = [string[]]@() } else { $peers = [string[]]@($PeerMacs) }   # a supplied $null is an empty list, not an omitted one
    }
    @(Get-AapNetAdapterProblem $Declaration $Adapters $targets ([string[]]@($HostLan)) $entries $HostInterface $peers) | ForEach-Object { Format-AapNetText $_ 197 } | Select-Object -First 64
}

function Get-AapHostNetworkSwitchProblems {
    <# The VM's switch (Verify check 9, contract Verify): the extensions enabled on it now are exactly the set P19 recorded for
       it (Baseline), and no HNS network uses it (HnsNetworks). Only the module's Verify reads these, so a consumer never
       calls this. A list that was not read ($null) is a problem, never an empty one. Any line: AAP_NetworkUntrusted. #>
    param([AllowNull()][AllowEmptyString()][string]$SwitchName, [AllowNull()][AllowEmptyCollection()][string[]]$Baseline,
        [AllowNull()][AllowEmptyCollection()][string[]]$Extensions, [AllowNull()][AllowEmptyCollection()][string[]]$HnsNetworks)
    @(Get-AapNetSwitchProblem $SwitchName $Baseline $Extensions $HnsNetworks) | ForEach-Object { Format-AapNetText $_ 197 } | Select-Object -First 64
}

# ---- the declaration -----------------------------------------------------------------------------------------------------

function Get-AapNetDeclarationProblem($Request, $d) {
    if ((@(Get-AapNetNames $d | Sort-Object) -join ',') -cne (@($script:DeclarationKeys | Sort-Object) -join ',')) { return "the declaration's keys are not exactly $($script:DeclarationKeys -join ', ')" }   # check:decl-keys
    $schema = Get-AapNetField $d 'schema'
    if (-not (Test-AapNetInt $schema) -or $schema -ne 2 -or [string](Get-AapNetField $d 'kind') -cne 'host_network_attach') { return 'the declaration is not a host_network_attach of schema 2' }   # check:decl-keys
    $p = New-Object Collections.Generic.List[string]
    $id = [string](Get-AapNetField $d 'vm_id'); $name = [string](Get-AapNetField $d 'vm_name'); $prof = [string](Get-AapNetField $d 'profile')
    if ($id -cne [string](Get-AapNetField $Request 'VmId') -or $name -cne [string](Get-AapNetField $Request 'VmName') -or $prof -cne [string](Get-AapNetField $Request 'Profile')) {   # check:decl-echo
        $p.Add("the declaration is for $(Format-AapNetText $name) ($(Format-AapNetText $prof), $(Format-AapNetText $id)), not the VM Attach was asked for")
    }
    $sw = Get-AapHostNetworkSwitchName $name
    if ($id -cnotmatch $script:GuidRe -or -not (($prof -ceq 'windows' -and $sw -cmatch '-win\z') -or ($prof -ceq 'linux' -and $sw -cmatch '-linux\z'))) {   # check:decl-vm
        $p.Add("the declaration's VM $(Format-AapNetText $name) ($(Format-AapNetText $prof), $(Format-AapNetText $id)) is not a runner clone or build VM of that profile")
    }
    $net = Split-AapNetPrefix ([string](Get-AapNetField $d 'subnet'))
    if ($null -eq $net -or $net.Width -ne 32 -or $net.Bits -lt 16 -or $net.Bits -gt 30) { $p.Add("the subnet $(Format-AapNetText (Get-AapNetField $d 'subnet')) is not an IPv4 network of /16 to /30"); return $p.ToArray() }   # check:decl-subnet
    if (-not (Test-AapNetPrivate $net)) { $p.Add("the subnet $($net.Text) is not inside a private fixed range"); return $p.ToArray() }   # check:decl-subnet-private
    # The guest's static addressing: no DHCP serves it (contract, Attach).
    $gw = [string](Get-AapNetField $d 'gateway')
    if (-not (Test-AapNetHost $net (Split-AapNetAddress $gw))) { $p.Add("the gateway $(Format-AapNetText $gw) is not a host address of $($net.Text)") }   # check:decl-gateway
    $addr = [string](Get-AapNetField $d 'address')
    if (-not (Test-AapNetHost $net (Split-AapNetAddress $addr)) -or $addr -ceq $gw) { $p.Add("the address $(Format-AapNetText $addr) is not a host address of $($net.Text) other than the gateway") }   # check:decl-address
    # The static MAC Attach gives the adapter before its first start, of the module's range: the host's permanent neighbour
    # entry pairs it with the guest's address, which is meant to keep a guest's ARP from moving the host's own entry for that
    # address (host-neighbour poisoning protection: contract, Attach; Open points, 1; its lab proof is open).
    $mac = [string](Get-AapNetField $d 'mac')
    if (-not (Test-AapNetMac $mac)) { $p.Add("the mac $(Format-AapNetText $mac) is not one static MAC of the module's range $($script:MacRange)-xx-xx-xx") }   # check:decl-mac
    # The narrowed exceptions, none by default: one private resolver the owner chose, outside the subnet, as up to two
    # endpoints, UDP and TCP to port 53.
    $ends = Get-AapNetList $d 'endpoints'
    if ($null -eq $ends -or $ends.Count -gt 2) { $p.Add('the endpoints are not a list of at most 2') }   # check:decl-endpoints
    $dns = New-Object Collections.Generic.List[string]
    $seen = New-Object Collections.Generic.List[string]
    foreach ($e in $ends) {
        if ((@(Get-AapNetNames $e | Sort-Object) -join ',') -cne (@($script:EndpointKeys | Sort-Object) -join ',')) { $p.Add('an endpoint is not exactly address, protocol and port'); continue }   # check:decl-endpoint
        $text = [string](Get-AapNetField $e 'address'); $proto = [string](Get-AapNetField $e 'protocol'); $port = Get-AapNetField $e 'port'
        $ip = Split-AapNetAddress $text
        if ($null -eq $ip -or -not (Test-AapNetPrivate $ip) -or (Test-AapNetCover $net $ip)) { $p.Add("the endpoint $(Format-AapNetText $text) is not one private IPv4 address outside $($net.Text)"); continue }   # check:decl-endpoint-address
        if (@('TCP', 'UDP') -cnotcontains $proto -or -not ((Test-AapNetInt $port) -and $port -eq 53)) { $p.Add("the endpoint $text is not narrowed to TCP or UDP and port 53"); continue }   # check:decl-endpoint-narrow
        $key = "$text $proto $port"
        if ($seen -ccontains $key) { $p.Add("the endpoint $key is declared twice") }   # check:decl-endpoints
        $seen.Add($key)
        if ($dns -cnotcontains $text) { $dns.Add($text) }
    }
    if ($dns.Count -gt 1) { $p.Add("the endpoints name $($dns.Count) addresses, not one resolver") }   # check:decl-endpoint-one
    # The resolvers the guest is given: public ones (global unicast) need no Allow; the private one only as the endpoints.
    $res = Get-AapNetList $d 'resolvers'
    if ($null -eq $res -or $res.Count -lt 1 -or $res.Count -gt 2) { $p.Add('the resolvers are not a list of one or two addresses'); return $p.ToArray() }   # check:decl-resolvers
    $listed = New-Object Collections.Generic.List[string]
    foreach ($r in $res) {
        $text = [string]$r
        $ip = Split-AapNetAddress $text
        if ($null -eq $ip -or $listed -ccontains $text) { $p.Add("the resolver $(Format-AapNetText $text) is not one IPv4 address, listed once"); continue }   # check:decl-resolver
        $listed.Add($text)
        if ((Test-AapNetFixed $ip) -and $dns -cnotcontains $text) { $p.Add("the resolver $text is neither public nor a declared endpoint on port 53") }   # check:decl-resolver-private
    }
    # No exception for an address the guest is not told to use.
    foreach ($x in $dns) { if ($listed -cnotcontains $x) { $p.Add("the endpoint $x is not one of the resolvers") } }   # check:decl-endpoint-resolver
    $p.ToArray()
}

# ---- the read-back -------------------------------------------------------------------------------------------------------

function Get-AapNetAdapterProblem($d, $Adapters, $HostDeny, [string[]]$HostLan, $Neighbors, $HostInterface, $PeerMacs) {
    $echo = @{ VmId = (Get-AapNetField $d 'vm_id'); VmName = (Get-AapNetField $d 'vm_name'); Profile = (Get-AapNetField $d 'profile') }
    $bad = @(Get-AapNetDeclarationProblem $echo $d)
    if ($bad.Count) { return @($bad | ForEach-Object { "declaration: $_" }) }   # check:adapter-declaration
    if ($null -eq $Adapters) { $Adapters = @() }
    if ($Adapters.Count -ne 1) { return "the VM has $($Adapters.Count) network adapters, not 1" }   # check:adapter-count
    $n = $Adapters[0]
    $missing = @($script:AdapterKeys | Where-Object { -not (Test-AapNetField $n $_) })
    if ($missing.Count) { return "the adapter read-back lacks $($missing -join ', ')" }   # check:adapter-keys
    $v = @{}
    foreach ($k in 'SwitchName', 'SwitchType', 'MacAddress', 'DhcpGuard', 'RouterGuard', 'MacAddressSpoofing', 'PortMirroringMode', 'VlanMode', 'StormLimit', 'LegacyAcls') { $v[$k] = Format-AapNetText (Get-AapNetField $n $k) }
    $p = New-Object Collections.Generic.List[string]
    $sw = Get-AapHostNetworkSwitchName ([string](Get-AapNetField $d 'vm_name'))
    $addr = [string](Get-AapNetField $d 'address')
    $gw = [string](Get-AapNetField $d 'gateway')
    $mac = [string](Get-AapNetField $d 'mac')
    if ([string](Get-AapNetField $n 'SwitchName') -cne $sw -or [string](Get-AapNetField $n 'SwitchType') -cne 'Internal') { $p.Add("the adapter is on '$($v.SwitchName)' ($($v.SwitchType)), not on the internal switch $sw") }   # check:switch
    if ([string](Get-AapNetField $n 'DhcpGuard') -cne 'On') { $p.Add("DHCP guard is '$($v.DhcpGuard)', not On") }   # check:dhcp-guard
    if ([string](Get-AapNetField $n 'RouterGuard') -cne 'On') { $p.Add("router guard is '$($v.RouterGuard)', not On") }   # check:router-guard
    if ([string](Get-AapNetField $n 'MacAddressSpoofing') -cne 'Off') { $p.Add("MAC address spoofing is '$($v.MacAddressSpoofing)', not Off") }   # check:mac-spoofing
    # The adapter's MAC is the declared one: the permanent neighbour entry pins the guest's address to it (contract, Attach).
    # Hyper-V's own text for a MAC (twelve hex digits, no separators) is normalised here, by the check: a provider passes it
    # through as read, because its module cannot see this one's functions (contract, Read-back). Anything else compares as read.
    if ((ConvertTo-AapNetMac ([string](Get-AapNetField $n 'MacAddress'))) -cne $mac) { $p.Add("the adapter's MAC address is '$($v.MacAddress)', not the declared $($mac)") }   # check:adapter-mac
    # No other adapter on the switch carries the declared MAC (contract, Verify check 2): MAC address spoofing Off cannot tell
    # two ports with one MAC apart, and the host's entry would pair the address with both. Only the module reads every
    # adapter, so only its Verify passes -PeerMacs (a consumer's read-back passes none and nothing is compared). Given, it
    # lists every other adapter on the switch, the host's own management adapter among them: an empty list, or an entry that
    # is not a MAC, is a discovery that failed and certifies nothing. MACs compare as hex digits, however they are written.
    if ($null -ne $PeerMacs) {
        if ($PeerMacs.Count -eq 0) { $p.Add("no other adapter was listed on $($sw), where the host's own is always one: the peer MACs were not read") }   # check:peer-empty
        $bad = @($PeerMacs | Where-Object { -not (Test-AapNetPeerMac ([string]$_)) })
        if ($bad.Count) { $p.Add("$($bad.Count) of the $($PeerMacs.Count) peer MACs on $($sw) are not MACs, the first '$(Format-AapNetText $bad[0])'") }   # check:peer-malformed
        $key = Get-AapNetMacKey $mac
        $clash = @($PeerMacs | Where-Object { (Get-AapNetMacKey $_) -ceq $key })
        if ($clash.Count) { $p.Add("another adapter on $sw carries the declared MAC $($mac)") }   # check:peer-mac-clash
    }
    if ([string](Get-AapNetField $n 'PortMirroringMode') -cne 'None') { $p.Add("port mirroring is '$($v.PortMirroringMode)', not None") }   # check:mirroring
    if (@('Untagged', 'Access') -cnotcontains [string](Get-AapNetField $n 'VlanMode')) { $p.Add("the VLAN mode is '$($v.VlanMode)', not Untagged or Access") }   # check:vlan
    if ([string](Get-AapNetField $n 'StormLimit') -cne $script:StormLimit) { $p.Add("the storm limit is '$($v.StormLimit)', not $($script:StormLimit)") }   # check:storm-limit
    $legacy = Get-AapNetField $n 'LegacyAcls'
    if (-not (Test-AapNetInt $legacy) -or $legacy -ne 0) { $p.Add("the adapter has '$($v.LegacyAcls)' legacy port ACLs, not 0") }   # check:legacy-acls
    # The switch's other VMs: none beside a build VM; beside a runner clone, only runner clones of its profile (contract, Switches).
    $build = $sw -clike 'aap-build-*'
    $odd = @(@(Get-AapNetField $n 'Peers') | Where-Object { $build -or (Get-AapHostNetworkSwitchName ([string]$_)) -cne $sw } | ForEach-Object { [string]$_ })
    if ($odd.Count) { $p.Add("$(if ($build) { 'the build VM' } else { 'the runner clone' }) shares $sw with $(Format-AapNetText ($odd -join ', ') 80)$(if (-not $build) { ', not only runner clones of its profile' })") }   # check:peers
    # Host-neighbour poisoning protection (contract, Attach; Open points, 1): the host's permanent neighbour entry pairs the
    # guest's address with its MAC, so no guest's ARP is meant to move the host's own entry for it. That protects what the host
    # sends the guest and nothing else (contract, Limitations: clone-to-clone residuals); its lab proof is open. Only the module's own
    # Verify passes -Neighbors (what it read from Get-NetNeighbor) and -HostInterface (the adapter it resolved); a consumer's
    # read-back passes neither.
    if ($null -ne $Neighbors) {   # check:neighbor-entries
        $ifx = Get-AapNetHostInterface $HostInterface
        if ($null -eq $ifx) { $p.Add("the switch's management adapter was not resolved: the neighbour entry has no interface to be held against") }   # check:neighbor-interface-given
        if ($Neighbors.Count -ne 1) { $p.Add("the host holds $($Neighbors.Count) neighbour entries for $($addr), not 1") }   # check:neighbor-count
        else {
            $e = $Neighbors[0]
            $missing = @($script:NeighborKeys | Where-Object { -not (Test-AapNetField $e $_) })
            if ($missing.Count) { $p.Add("the neighbour entry read-back lacks $($missing -join ', ')") }   # check:neighbor-keys
            else {
                if ([string](Get-AapNetField $e 'IPAddress') -cne $addr) { $p.Add("the neighbour entry is for '$(Format-AapNetText (Get-AapNetField $e 'IPAddress'))', not the guest's $($addr)") }   # check:neighbor-address
                if ([string](Get-AapNetField $e 'State') -cne 'Permanent') { $p.Add("the neighbour entry's state is '$(Format-AapNetText (Get-AapNetField $e 'State'))', not Permanent") }   # check:neighbor-state
                if ([string](Get-AapNetField $e 'LinkLayerAddress') -cne $mac) { $p.Add("the neighbour entry's link-layer address is '$(Format-AapNetText (Get-AapNetField $e 'LinkLayerAddress'))', not the declared $($mac)") }   # check:neighbor-mac
                # The adapter by identity: an alias is only a name another adapter can be given, so the entry must sit on the
                # interface index the module resolved, and show that adapter's own alias.
                if ($null -ne $ifx -and ([string](Get-AapNetField $e 'InterfaceIndex') -cne $ifx.Index -or [string](Get-AapNetField $e 'InterfaceAlias') -cne $ifx.Alias)) { $p.Add("the neighbour entry is on interface $(Format-AapNetText (Get-AapNetField $e 'InterfaceIndex')) '$(Format-AapNetText (Get-AapNetField $e 'InterfaceAlias'))', not the switch's management adapter $($ifx.Index) '$(Format-AapNetText $ifx.Alias)'") }   # check:neighbor-interface
            }
        }
    }

    $rules = New-Object Collections.Generic.List[object]
    $i = 0
    foreach ($r in @(Get-AapNetField $n 'Acls')) {
        $i++
        $missing = @($script:RuleKeys | Where-Object { -not (Test-AapNetField $r $_) })
        if ($missing.Count) { $p.Add("rule $i lacks $($missing -join ', ')"); continue }   # check:rule-keys
        $extra = @(Get-AapNetNames $r | Where-Object { $script:RuleKeys -cnotcontains $_ })
        if ($extra.Count) { $p.Add("rule $i has unknown $(Format-AapNetText ($extra -join ', '))"); continue }   # check:rule-extra
        $act = [string](Get-AapNetField $r 'Action'); $dir = [string](Get-AapNetField $r 'Direction')
        if (@('Allow', 'Deny') -cnotcontains $act -or $script:Directions -cnotcontains $dir) { $p.Add("rule $i is '$(Format-AapNetText $act)' '$(Format-AapNetText $dir)', not Allow or Deny, Inbound or Outbound"); continue }   # check:rule-kind
        # Every rule stateless and in no isolation network: either would let traffic past what the rule list shows.
        if ([string](Get-AapNetField $r 'Stateful') -cne 'False') { $p.Add("rule $i is stateful '$(Format-AapNetText (Get-AapNetField $r 'Stateful'))', not False"); continue }   # check:rule-stateful
        if (@('0', '') -cnotcontains [string](Get-AapNetField $r 'IsolationId')) { $p.Add("rule $i has isolation id '$(Format-AapNetText (Get-AapNetField $r 'IsolationId'))', not 0"); continue }   # check:rule-isolation
        $w = Get-AapNetField $r 'Weight'
        if (-not (Test-AapNetInt $w) -or $w -lt [int]::MinValue -or $w -gt [int]::MaxValue) { $p.Add("rule $i has no Int32 weight"); continue }   # check:rule-weight
        $remote = Split-AapNetPrefix ([string](Get-AapNetField $r 'RemoteAddress'))
        if ($null -eq $remote) { $p.Add("rule $i's remote address '$(Format-AapNetText (Get-AapNetField $r 'RemoteAddress'))' is not an address or a prefix"); continue }   # check:rule-remote
        # What narrows the rule below its remote address: a deny narrowed by anything does not deny the range.
        $scope = New-Object Collections.Generic.List[string]
        $localText = [string](Get-AapNetField $r 'LocalAddress')
        $local = $null
        if (-not (Test-AapNetAnyAddress $localText $remote.Width)) { $scope.Add('local address'); $local = Split-AapNetPrefix $localText }   # check:scope-local-address
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'Protocol')))) { $scope.Add('protocol') }   # check:scope-protocol
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'LocalPort')))) { $scope.Add('local port') }   # check:scope-local-port
        if (-not (Test-AapNetAny ([string](Get-AapNetField $r 'RemotePort')))) { $scope.Add('remote port') }   # check:scope-remote-port
        $rules.Add([pscustomobject]@{ N = $i; Action = $act; Direction = $dir; Remote = $remote; Local = $local; Weight = [long]$w; Scope = $scope.ToArray()
                Protocol = (ConvertTo-AapNetProtocol ([string](Get-AapNetField $r 'Protocol'))); RemotePort = ([string](Get-AapNetField $r 'RemotePort')).Trim() })
    }
    # The source pin: the one outbound Allow of every IPv4 destination from the guest's own address, above the catch-all deny
    # and below every deny it must not lift (contract, Rules and weights).
    $pins = @($rules | Where-Object { $_.Action -ceq 'Allow' -and (Test-AapNetPinRule $_ $addr) })

    # Rule (i): every fixed range denied in both directions, unscoped and above the source pin; the host-specific targets
    # covered the same way, none of them an endpoint, and none a public IPv4 address, which the decided shape does not cover
    # (contract, Limitations).
    foreach ($range in $script:FixedDeny) {
        $rp = Split-AapNetPrefix $range
        foreach ($dir in $script:Directions) {
            $floor = Get-AapNetFloor $pins $dir $rp
            if (-not @($rules | Where-Object { $_.Remote.Text -ceq $range -and (Test-AapNetFullDeny $_ $dir $floor) }).Count) { $p.Add("no unscoped $dir deny for $range") }   # check:fixed-deny
        }
    }
    $ends = @(Get-AapNetField $d 'endpoints' | ForEach-Object { ConvertTo-AapNetEndpoint $_ })
    if ($null -ne $HostDeny -and $HostDeny.Count -eq 0) { $p.Add('no host-specific targets: host discovery found nothing') }   # check:host-empty
    if ($null -ne $HostDeny -and $HostDeny.Count -and -not @($HostDeny | Where-Object { $g = Split-AapNetPrefix $_; $null -ne $g -and $g.Text -ceq "$gw/32" }).Count) { $p.Add("the host-specific targets lack the gateway $($gw): host discovery is incomplete") }   # check:host-gateway
    if ($null -ne $HostDeny -and -not @($HostLan | Where-Object { $_ -and $HostDeny -ccontains $_ }).Count) { $p.Add('the host-specific targets hold no address of a host interface that is not a vEthernet adapter: host discovery is incomplete') }   # check:host-lan
    foreach ($t in $HostDeny) {
        $tp = Split-AapNetPrefix $t
        if ($null -eq $tp) { $p.Add("the host-specific target '$(Format-AapNetText $t)' is not an address or a prefix"); continue }   # check:host-deny
        if ($tp.Width -eq 32 -and -not (Test-AapNetFixed $tp)) { $p.Add("the host's $($tp.Text) is public IPv4, outside the enforcement shape: not certified (contract, Limitations)"); continue }   # check:host-public
        foreach ($dir in $script:Directions) {
            $floor = Get-AapNetFloor $pins $dir $tp
            if (-not @($rules | Where-Object { (Test-AapNetFullDeny $_ $dir $floor) -and (Test-AapNetCover $_.Remote $tp) }).Count) { $p.Add("no unscoped $dir deny covers the host's $($tp.Text)") }   # check:host-deny
        }
        foreach ($e in $ends) {
            if (Test-AapNetCover $tp $e.Ip) { $p.Add("the endpoint $($e.Text) lies in the host's $($tp.Text)") }   # check:host-endpoint
        }
    }

    # Rule (ii): every allow is the source pin or exactly a declared endpoint; an endpoint's allow outweighs every deny of its
    # direction that covers it; every endpoint has an allow in both directions. With no endpoint declared (the default) the
    # source pin is the only allow.
    if ($pins.Count -ne 1) { $p.Add("there are $($pins.Count) source pins, not 1") }   # check:pin-count
    if ($pins.Count -eq 1 -and -not @($rules | Where-Object { $_.Remote.Text -ceq '0.0.0.0/0' -and (Test-AapNetFullDeny $_ 'Outbound' ([long]::MinValue)) -and $_.Weight -lt $pins[0].Weight }).Count) {   # check:pin-catch-all
        $p.Add("no unscoped Outbound deny for 0.0.0.0/0 below the source pin (weight $($pins[0].Weight))")
    }
    foreach ($dir in $script:Directions) {
        $allows = @($rules | Where-Object { $_.Action -ceq 'Allow' -and $_.Direction -ceq $dir })
        foreach ($a in $allows) {
            if (@($pins | Where-Object { $_.N -eq $a.N }).Count) { continue }
            $what = "rule $($a.N): the $dir allow $($a.Remote.Text)"
            if (-not @($ends | Where-Object { Test-AapNetEndpointRule $a $_ $addr }).Count) { $p.Add("$what$(if ($a.Scope.Count) { " [$($a.Scope -join ', ')]" }) is not exactly a declared endpoint"); continue }   # check:allow-declared
            foreach ($x in @($rules | Where-Object { $_.Action -ceq 'Deny' -and $_.Direction -ceq $dir -and (Test-AapNetCover $_.Remote $a.Remote) })) {
                if ($x.Weight -ge $a.Weight) { $p.Add("$what (weight $($a.Weight)) does not outweigh the deny $($x.Remote.Text) (weight $($x.Weight))") }   # check:allow-weight
            }
        }
        foreach ($e in $ends) {
            if (-not @($allows | Where-Object { Test-AapNetEndpointRule $_ $e $addr }).Count) { $p.Add("the endpoint $($e.Text) has no $dir allow") }   # check:endpoint-allow
        }
    }
    $p.ToArray()
}

# Whether $r denies everything to and from its remote range in $Dir: a Deny in that direction that nothing else narrows,
# heavier than $Floor (the source pin's weight where the pin covers the range, so the pin does not lift it).
function Test-AapNetFullDeny($r, [string]$Dir, [long]$Floor) {
    if ($r.Action -cne 'Deny') { return $false }   # check:deny-action
    if ($r.Direction -cne $Dir) { return $false }   # check:deny-direction
    if ($r.Scope.Count) { return $false }   # check:deny-unscoped
    if ($r.Weight -le $Floor) { return $false }   # check:deny-floor
    $true
}

# The heaviest source pin of direction $Dir that covers $T; the lowest Int64 when none does.
function Get-AapNetFloor($Pins, [string]$Dir, $T) {
    $f = [long]::MinValue
    foreach ($x in @($Pins | Where-Object { $_.Direction -ceq $Dir -and (Test-AapNetCover $_.Remote $T) })) { $f = [Math]::Max($f, $x.Weight) }
    $f
}

# Whether allow $r is the source pin: outbound, every IPv4 destination, narrowed only to the guest's own address.
function Test-AapNetPinRule($r, [string]$Address) {
    if ($r.Direction -cne 'Outbound' -or $r.Remote.Text -cne '0.0.0.0/0' -or ($r.Scope -join ',') -cne 'local address') { return $false }   # check:pin-shape
    if ($null -eq $r.Local -or $r.Local.Text -cne "$Address/32") { return $false }   # check:pin-local
    $true
}

# Whether allow $r is exactly endpoint $e: its one address, its protocol and its remote port, the guest's own address as
# the local one, and nothing else narrowed.
function Test-AapNetEndpointRule($r, $e, [string]$Address) {
    if ($r.Remote.Bits -ne $r.Remote.Width -or $r.Remote.Address -cne $e.Address) { return $false }   # check:allow-address
    if (($r.Scope -join ',') -cne 'local address,protocol,remote port' -or $r.Protocol -cne $e.Protocol -or $r.RemotePort -cne [string]$e.Port) { return $false }   # check:allow-port
    if ($null -eq $r.Local -or $r.Local.Text -cne "$Address/32") { return $false }   # check:allow-local
    $true
}

# ---- fields, addresses and text ------------------------------------------------------------------------------------------

# A field of a hashtable or an object, whether it is there at all (a missing field is never read as a value), and the names.
function Test-AapNetField($o, [string]$Name) {
    if ($o -is [Collections.IDictionary]) { return $o.Contains($Name) }
    $null -ne $o -and $null -ne $o.PSObject.Properties[$Name]
}
function Get-AapNetField($o, [string]$Name) {
    if (-not (Test-AapNetField $o $Name)) { return }
    if ($o -is [Collections.IDictionary]) { $o[$Name] } else { $o.PSObject.Properties[$Name].Value }
}
function Get-AapNetNames($o) {
    if ($o -is [Collections.IDictionary]) { @($o.Keys | ForEach-Object { [string]$_ }) } elseif ($null -ne $o) { @($o.PSObject.Properties | ForEach-Object { $_.Name }) }
}
# A field that must be a list, as the list itself (empty or not); nothing when it is missing or not a list.
function Get-AapNetList($o, [string]$Name) {
    if (-not (Test-AapNetField $o $Name)) { return }
    $v = $(if ($o -is [Collections.IDictionary]) { , $o[$Name] } else { , $o.PSObject.Properties[$Name].Value })
    if ($v -is [Collections.IList]) { , $v }   # check:list-type
}
function Test-AapNetInt($v) { $v -is [int] -or $v -is [long] }

# A field that leaves a rule unrestricted: '', '*' or ANY (D2: which one Hyper-V shows for an unset field). For a local
# address the wildcard of the remote address's family counts too (0.0.0.0/0, ::/0).
function Test-AapNetAny([string]$Text) { @('', '*', 'any') -contains $Text.Trim() }
function Test-AapNetAnyAddress([string]$Text, [int]$Width) { (Test-AapNetAny $Text) -or $Text.Trim() -ceq $(if ($Width -eq 32) { '0.0.0.0/0' } else { '::/0' }) }

function ConvertTo-AapNetProtocol([string]$Text) {
    $t = $Text.Trim().ToUpperInvariant()
    if ($t -ceq '6') { 'TCP' } elseif ($t -ceq '17') { 'UDP' } else { $t }
}

# A declared endpoint, already checked, as @{ Address; Ip; Protocol; Port; Text }.
function ConvertTo-AapNetEndpoint($e) {
    $addr = [string](Get-AapNetField $e 'address'); $proto = [string](Get-AapNetField $e 'protocol'); $port = [int](Get-AapNetField $e 'port')
    @{ Address = $addr; Ip = (Split-AapNetPrefix $addr); Protocol = $proto; Port = $port; Text = "$addr $proto $port" }
}

# An address ('172.31.250.1', an address alone is a /32 or /128) or a prefix ('10.0.0.0/8') in canonical text, as
# @{ Text; Address; Bytes; Bits; Width }; $null for anything else: another spelling (upper-case IPv6 and a zero-padded prefix
# length too), host bits under the prefix, a wildcard.
function Split-AapNetPrefix([string]$Text) {
    $parts = $Text.Split('/')
    $ip = $null
    if ($parts.Count -gt 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or $ip.ToString() -cne $parts[0]) { return $null }   # check:addr-canonical
    $bytes = $ip.GetAddressBytes()
    $width = $bytes.Length * 8
    $bits = $width
    if ($parts.Count -eq 2) {
        if ($parts[1] -cnotmatch '^(0|[1-9][0-9]{0,2})\z' -or [int]$parts[1] -gt $width) { return $null }   # check:addr-prefix-length
        $bits = [int]$parts[1]
    }
    for ($i = $bits; $i -lt $width; $i++) { if ($bytes[$i -shr 3] -band (0x80 -shr ($i % 8))) { return $null } }   # check:addr-host-bits
    @{ Text = "$($ip.ToString())/$bits"; Address = $ip.ToString(); Bytes = $bytes; Bits = $bits; Width = $width }
}

# One IPv4 address in canonical text ('172.31.250.1', no prefix), as Split-AapNetPrefix gives it; $null for anything else.
function Split-AapNetAddress([string]$Text) {
    $ip = Split-AapNetPrefix $Text
    if ($null -ne $ip -and $ip.Width -eq 32 -and $Text -ceq $ip.Address) { $ip }   # check:addr-single
}

# Whether address or prefix $P lies inside a fixed range.
function Test-AapNetFixed($P) { @($script:FixedDeny | Where-Object { Test-AapNetCover (Split-AapNetPrefix $_) $P }).Count -gt 0 }

# Whether IPv4 address or prefix $P is private: inside a fixed range a NAT routes unicast in, 10.0.0.0/8, 172.16.0.0/12,
# 192.168.0.0/16 or 100.64.0.0/10.
function Test-AapNetPrivate($P) { $P.Width -eq 32 -and @($script:PrivateRanges | Where-Object { Test-AapNetCover (Split-AapNetPrefix $_) $P }).Count -gt 0 }

# Whether $Text is one static MAC of the module's range (contract, Attach): canonical text, six pairs of uppercase hex
# joined by dashes, inside the range the module owns and Allocate takes the lowest of. (The text Hyper-V itself reports an
# adapter's MAC as is an open lab question; check 2 normalises it first, ConvertTo-AapNetMac.)
function Test-AapNetMac([string]$Text) {
    if ($Text -cnotmatch '^[0-9A-F]{2}(-[0-9A-F]{2}){5}\z') { return $false }   # check:mac-canonical
    if ($Text -cnotlike "$($script:MacRange)-*") { return $false }   # check:mac-range
    $true
}

# Hyper-V's adapter MAC text, twelve hex digits with no separators, as the contract's dashed uppercase form: what check 2
# compares an adapter's MAC through (contract, Read-back), the one place it is normalised: a provider read-back passes the
# text through as read. Anything that is not exactly twelve uppercase hex digits passes through unchanged, so the check
# still fails closed on it; the exact text Hyper-V reports is a lab question (D2).
function ConvertTo-AapNetMac([string]$Text) {
    if ($Text -cmatch '^[0-9A-F]{12}\z') { ($Text -split '(.{2})' -ne '') -join '-' } else { $Text }   # check:adapter-mac-form
}

# A MAC as its hex digits in upper case, however it is written ('02-A0-98-00-00-01', '02a098000001', '02:A0:98:00:00:01'): what
# two MACs are compared by when a clash matters more than the form (contract, Verify check 2); not what check 2 compares the
# declared MAC by, which is exact.
function Get-AapNetMacKey([string]$Text) { ([string]$Text -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() }

# Whether $Text is a MAC as an adapter's MAC is read: twelve hex digits, in pairs joined by dashes or by colons, or run
# together (Hyper-V's own text). Anything else is not one.
function Test-AapNetPeerMac([string]$Text) {
    ($Text -cmatch '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}\z') -or ($Text -cmatch '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\z') -or ($Text -cmatch '^[0-9A-Fa-f]{12}\z')
}

# The switch's management adapter as the module resolved it, @{ Index; Alias } in canonical text; nothing when it is not a
# positive interface index (digits, no sign, no leading zero) with a printable alias.
function Get-AapNetHostInterface($H) {
    if ($null -eq $H) { return }
    $i = [string](Get-AapNetField $H 'InterfaceIndex'); $a = [string](Get-AapNetField $H 'InterfaceAlias')
    if ($i -cmatch '^[1-9][0-9]{0,9}\z' -and $a -cmatch '^[ -~]+\z') { @{ Index = $i; Alias = $a } }
}

# Verify check 9: the extensions enabled on the switch are exactly the baseline P19 recorded for it, and no HNS network uses it.
# Names compare exactly. A baseline that was not recorded, or a list that was not read, certifies nothing.
function Get-AapNetSwitchProblem($SwitchName, $Baseline, $Extensions, $Hns) {
    $p = New-Object Collections.Generic.List[string]
    $name = Format-AapNetText $SwitchName
    if ($null -eq $Baseline) { $p.Add("no enabled-extension baseline is recorded for the switch $name"); return $p.ToArray() }   # check:switch-baseline
    if ($null -eq $Extensions -or $null -eq $Hns) { $p.Add("the extensions or the HNS networks of the switch $name were not read"); return $p.ToArray() }   # check:switch-read
    $extra = @($Extensions | Where-Object { $Baseline -cnotcontains [string]$_ } | ForEach-Object { [string]$_ })
    $gone = @($Baseline | Where-Object { $Extensions -cnotcontains [string]$_ } | ForEach-Object { [string]$_ })
    if ($extra.Count) { $p.Add("the switch $name has an extension enabled beyond its baseline: $(Format-AapNetText ($extra -join ', ') 80)") }   # check:switch-extension-extra
    if ($gone.Count) { $p.Add("the switch $name lacks the baseline extension $(Format-AapNetText ($gone -join ', ') 80)") }   # check:switch-extension-missing
    if (@($Hns).Count) { $p.Add("an HNS network uses the switch $name`: $(Format-AapNetText (@($Hns) -join ', ') 80)") }   # check:switch-hns
    $p.ToArray()
}

# Whether prefix $P contains $T, an address or a prefix of the same family.
function Test-AapNetCover($P, $T) {
    if ($P.Width -ne $T.Width -or $T.Bits -lt $P.Bits) { return $false }   # check:cover-width
    for ($i = 0; $i -lt $P.Bits; $i++) {
        $m = 0x80 -shr ($i % 8)
        if (($P.Bytes[$i -shr 3] -band $m) -ne ($T.Bytes[$i -shr 3] -band $m)) { return $false }   # check:cover-bits
    }
    $true
}

# Whether $Ip is a host address of the IPv4 network $Net: inside it, neither its network nor its broadcast address.
function Test-AapNetHost($Net, $Ip) {
    if ($null -eq $Ip -or -not (Test-AapNetCover $Net $Ip)) { return $false }   # check:host-address
    $hb = @(for ($i = $Net.Bits; $i -lt 32; $i++) { [int][bool]($Ip.Bytes[$i -shr 3] -band (0x80 -shr ($i % 8))) })
    ($hb -contains 0) -and ($hb -contains 1)
}

# A value as one short printable line for a problem text.
function Format-AapNetText($Value, [int]$Max = 40) {
    $s = [string]$Value -replace '[^ -~]', '?'
    if ($s.Length -gt $Max) { $s.Substring(0, $Max) + '...' } else { $s }
}

Export-ModuleMember -Function Get-AapHostNetworkFixedDeny, Get-AapHostNetworkMacRange, Get-AapHostNetworkSwitchName, Get-AapHostNetworkDeclarationProblems, Get-AapHostNetworkAdapterProblems, Get-AapHostNetworkSwitchProblems
